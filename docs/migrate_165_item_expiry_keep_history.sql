/* ═══════════════════════════════════════════════════════════════════
   تواريخ الصلاحية: نراكم ولا نمسح — والعرض الافتراضي «اللي له رصيد»
   ═══════════════════════════════════════════════════════════════════
   ── اللي كان بيحصل ──────────────────────────────────────────────
   المزامنة بتسأل eplus كل ليلة «الدفعات اللي `itm_qty > 0`» وبتعمل
   upsert. مابتمسحش، فالدفعة اللي خلصت بتفضل بآخر كمية اتشافت بيها.
   والتنظيف `item_expiry_prune()` كان بيمسح أي صف `synced_at` بقاله
   **10 أيام** — يعني:

     • الدفعة اللي خلصت النهاردة تفضل ظاهرة ١٠ أيام (قيس 2026-10-28:
       3,071 صف من 41,520 كانوا دفعات خلصت ولسه معروضة).
     • وبعد العشرة أيام **المعلومة بتضيع خالص** — مابيفضلش أي أثر إن
       الدفعة كانت موجودة ولا بكام، فسؤال «البضاعة دي راحت فين؟»
       مالوش إجابة.

   ── قرار المالك (2026-10-28) ────────────────────────────────────
   «ضيف في الجدول بشكل يومي بدون حذف ولا حاجة، لكن اعرض بشكل افتراضي
   اللي له رصيد».

   ── التغيير ─────────────────────────────────────────────────────
   1) **مفيش مسح**: `item_expiry_prune()` بقت بلا أي `delete`، ومهمة
      الكرون اتوقفت. الجدول بقى سجلًا تاريخيًا.
   2) **`first_seen` / `last_seen`**: أول وآخر يوم الدفعة اتشافت فيه
      في مزامنة. بتتعبّى بالتريجر، ومتبنية على توقيت القاهرة.
   3) **`item_expiry_log`**: سجل تغيّرات **يُلحق ولا يُعدّل** — كل مرة
      كمية دفعة تتغيّر بيتكتب سطر بـ(قبل، بعد، الفرق). ده أساس أي
      إجابة مستقبلية عن «اتباع كام واتحوّل كام واترمى كام»، لأن
      اللقطة لوحدها بتمسح التاريخ كل ليلة.
   4) **تعريف «له رصيد»**: الصف `last_seen` بتاعه = آخر يوم مزامنة
      **لفرعه**. `expiry_live_day(branch)` بترجّع اليوم ده، و
      `expiry_is_live(branch, last_seen)` بتحكم على الصف.
      ⚠️ بالفرع مش عام: لو مزامنة فرع وقعت ليلة، فروعه التانية
      مايتأثروش، والفرع الواقع بيفضل على آخر يوم ناجح بدل ما يختفي.

   ── مابيتغيّرش ──────────────────────────────────────────────────
   `expiry_source_for` (شريحة الصلاحية في طلبيات الأدوية) بتفلتر
   `synced_at > now() - 3 days` بنفسها، فوقف المسح مايأثرش عليها.

   ── حجم الجدول ──────────────────────────────────────────────────
   النمو مش 38 ألف صف في اليوم — الـupsert بيحدّث الموجود، فالزيادة
   هي الدفعات الجديدة بس (مئات في اليوم). والسجل `item_expiry_log`
   بيكبر بعدد التغيّرات لا أكتر.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── ١) أعمدة أول/آخر ظهور ──────────────────────────────────────── */
alter table public.item_expiry
  add column if not exists first_seen date,
  add column if not exists last_seen  date;

update public.item_expiry
   set first_seen = coalesce(first_seen, (synced_at at time zone 'Africa/Cairo')::date),
       last_seen  = coalesce(last_seen,  (synced_at at time zone 'Africa/Cairo')::date)
 where first_seen is null or last_seen is null;

create index if not exists item_expiry_live_idx
  on public.item_expiry (branch, last_seen, exp_date);

/* ── ٢) سجل التغيّرات — يُلحق ولا يُعدّل ────────────────────────── */
create table if not exists public.item_expiry_log (
  id          bigint generated always as identity primary key,
  branch      text        not null,
  itm_code    text        not null,
  exp_date    date        not null,
  day         date        not null,
  qty_before  numeric,
  qty_after   numeric     not null,
  diff        numeric     not null,
  kind        text        not null,          -- new | change
  logged_at   timestamptz not null default now()
);
create index if not exists item_expiry_log_day_idx  on public.item_expiry_log (day, branch);
create index if not exists item_expiry_log_item_idx on public.item_expiry_log (branch, itm_code, exp_date);

comment on table public.item_expiry_log is
  'سجل تغيّرات كميات الدفعات — يُلحق فقط. اللقطة في item_expiry بتتكتب فوق نفسها كل ليلة، فده المكان الوحيد اللي بيفضل فيه أثر إن دفعة نقصت أو خلصت.';

/* ── ٣) التريجر: الختم + أول/آخر ظهور + السجل ───────────────────── */
create or replace function public.item_expiry_stamp()
returns trigger language plpgsql as $fn$
declare v_day date := (now() at time zone 'Africa/Cairo')::date;
begin
  new.synced_at := now();
  new.last_seen := v_day;

  if tg_op = 'INSERT' then
    new.first_seen := coalesce(new.first_seen, v_day);
    insert into public.item_expiry_log(branch, itm_code, exp_date, day, qty_before, qty_after, diff, kind)
    values (new.branch, new.itm_code, new.exp_date, v_day, null, new.qty, new.qty, 'new');

  else
    new.first_seen := coalesce(old.first_seen, v_day);
    /* الكمية بس هي اللي تستاهل سطر — إعادة مزامنة بنفس الرقم مش حدث */
    if new.qty is distinct from old.qty then
      insert into public.item_expiry_log(branch, itm_code, exp_date, day, qty_before, qty_after, diff, kind)
      values (new.branch, new.itm_code, new.exp_date, v_day, old.qty, new.qty, new.qty - old.qty, 'change');
    end if;
  end if;

  return new;
end$fn$;

/* ── ٤) وقف المسح ───────────────────────────────────────────────── */
/* الدالة بتفضل موجودة عشان أي كرون أو نداء قديم مايقعش، بس بقت
   بلا أثر. المسح الوحيد المسموح بيه مستقبلًا لازم يكون قرار صريح. */
create or replace function public.item_expiry_prune()
returns int language plpgsql as $fn$
begin
  /* مفيش حذف — قرار المالك 2026-10-28: الجدول سجل تاريخي.
     راجع رأس migrate_165. */
  return 0;
end$fn$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'item_expiry_prune') then
    perform cron.unschedule('item_expiry_prune');
  end if;
exception when undefined_table or undefined_function or insufficient_privilege then
  raise notice 'pg_cron مش متاح هنا — تخطّي إلغاء الجدولة';
end $$;

/* ── ٥) تعريف «له رصيد» ─────────────────────────────────────────── */
create or replace function public.expiry_live_day(p_branch text)
returns date language sql stable set search_path to 'public' as $fn$
  select max(last_seen) from item_expiry where branch = p_branch;
$fn$;

create or replace function public.expiry_is_live(p_branch text, p_last_seen date)
returns boolean language sql stable set search_path to 'public' as $fn$
  select p_last_seen = public.expiry_live_day(p_branch);
$fn$;

revoke all on function public.expiry_live_day(text)          from public, anon;
revoke all on function public.expiry_is_live(text, date)     from public, anon;
grant execute on function public.expiry_live_day(text)       to authenticated;
grant execute on function public.expiry_is_live(text, date)  to authenticated;

notify pgrst, 'reload schema';
