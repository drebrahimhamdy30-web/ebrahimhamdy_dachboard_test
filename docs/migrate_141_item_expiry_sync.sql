/* ═══════════════════════════════════════════════════════════════════
   مزامنة تواريخ الصلاحية اليومية + استبعاد المنتهي والقديم
   ═══════════════════════════════════════════════════════════════════
   الـ4,775 صف اللي في `item_expiry` كانت **محمّلة بالإيد** مرة واحدة
   من سيرفر المعمورة. من غير مهمة مجدولة البيانات بتتعتّق والشاشة
   بتفضل تنصح بتحويل تشغيلات باعت خلاص.

   ── المزامنة ─────────────────────────────────────────────────────
   مهمة في `sync_jobs` اسمها `item_expiry` بياخدها نفس محرّك
   `sync_engine.ps1` اللي على جهاز الصيدلية — من غير أي تعديل في
   المحرّك، لأن خطواته JSON بالكامل.

   نقطتين في صياغة الـSQL مقصودتين:
     • **مافيش `where_new`/`where_window`** — ده لقطة كاملة مش تزايدي.
       المحرّك بيلزّق `WHERE` في آخر النص، واللقطة محتاجة `GROUP BY`
       بعد الـ`WHERE`، فالفلاتر كلها جوه `select` والمفاتيح سايبة فاضية.
     • **`sto_id` بيتحدد من اسم الفرع بـ`CASE`** — كل سيرفر فرع شايف
       الفروع الأربعة، وسيرفر سيدى بشر كانت نسخته من المعمورة ناقصة
       (3,878 صنف بدل 10,982). فكل سيرفر يجيب فرعه هو بس.
       الحروف العربية بـ`N'…'` عشان ماتعتمدش على ترتيب المقارنة.

   ⚠️ اللقطة **مابتمسحش** الصفوف اللي خلصت من المخزن — الـupsert
      بيحدّث اللي موجود وبس. فبدل ما نعتمد على مسح، `synced_at`
      بتتوسم بتريجر وأي صف ماوصلتهوش مزامنة من 3 أيام **بيتجاهل**.
      ودي كمان حماية لو المحرّك وقف: التوصيات تهدى لوحدها بدل ما
      تفضل تنصح ببيانات بايتة.

   ── استبعاد المنتهي فعلًا (باگ اتكشف في الاختبار) ───────────────
   5 من 68 مرشّح كان تاريخهم **عدّى خلاص** (أقدمهم 2026-06-01) —
   الشرط كان `exp_date < today + N شهر` وبس، فالماضي كله جواه.
   اتضاف `exp_date >= current_date`.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) وسم وقت المزامنة ────────────────────────────────────────── */
create or replace function public.item_expiry_stamp()
returns trigger language plpgsql as $t$
begin
  new.synced_at := now();
  return new;
end
$t$;

drop trigger if exists trg_item_expiry_stamp on public.item_expiry;
create trigger trg_item_expiry_stamp
  before insert or update on public.item_expiry
  for each row execute function public.item_expiry_stamp();

create index if not exists item_expiry_code_idx on public.item_expiry (itm_code, exp_date);

/* ── 2) الدالة: استبعاد المنتهي والبايت ────────────────────────── */
create or replace function public.expiry_source_for(p_branch text, p_code text)
returns table (branch text, qty numeric, exp_date date)
language sql
stable
as $fn$
  select e.branch, e.qty, e.exp_date
    from public.item_expiry e
    left join public.consumption_flat cf on cf.code = e.itm_code
   where e.itm_code = p_code
     and e.branch <> p_branch
     and e.synced_at > now() - interval '3 days'   -- لقطة بايتة = ماتتنصحش
     and e.exp_date >= current_date                -- عدّى خلاص = ماينفعش يتحوّل
     and e.exp_date <  current_date
         + ((select ps.expiry_months from public.purchase_settings ps where ps.id = 1)
            || ' months')::interval
     and e.qty > coalesce(
           case e.branch
             when 'المعمورة'     then cf.av_mamora
             when 'سان ستيفانو'  then cf.av_san
             when 'سيدى بشر'     then cf.av_bishr
             when 'السيوف'       then cf.av_seyouf
           end, 0) * greatest(0.5, (e.exp_date - current_date) / 30.0)
   order by e.exp_date asc, e.qty desc
   limit 1
$fn$;

revoke all on function public.expiry_source_for(text, text) from public, anon;
grant execute on function public.expiry_source_for(text, text) to authenticated, service_role;

/* ── 3) المهمة المجدولة ─────────────────────────────────────────── */
insert into public.sync_jobs
  (id, name, source_db, enabled, interval_minutes, window_days, window_refresh_minutes, sort_order, steps)
values (
  'item_expiry', 'تواريخ الصلاحية', 'Genius', true,
  1440,   -- مرة في اليوم؛ يتعدّل من شاشة إعدادات المؤسسة
  0, 0, 90,
  jsonb_build_array(jsonb_build_object(
    'select',
      'SELECT N''{branch}'' AS branch, t.itm_code, t.exp_date, t.qty FROM ('
      || 'SELECT itm_id AS itm_code, CONVERT(varchar(10), itm_expiry_date, 23) AS exp_date, SUM(itm_qty) AS qty '
      || 'FROM Item_Class_Store '
      || 'WHERE itm_qty > 0 AND itm_expiry_date IS NOT NULL '
      ||   'AND itm_expiry_date >= GETDATE() '
      ||   'AND itm_expiry_date < DATEADD(month, 36, GETDATE()) '
      ||   'AND sto_id = CASE N''{branch}'' '
      ||        'WHEN N''المعمورة'' THEN 1 '
      ||        'WHEN N''سان ستيفانو'' THEN 26 '
      ||        'WHEN N''سيدى بشر'' THEN 28 '
      ||        'WHEN N''السيوف'' THEN 29 END '
      || 'GROUP BY itm_id, itm_expiry_date) t',
    'target',   'item_expiry',
    'conflict', 'branch,itm_code,exp_date'
  ))
)
on conflict (id) do update
   set steps = excluded.steps, name = excluded.name, enabled = excluded.enabled,
       window_days = excluded.window_days, window_refresh_minutes = excluded.window_refresh_minutes,
       updated_at = now();

insert into public.sync_branch_state (job_id, branch, enabled)
select 'item_expiry', b.name, true from public.branches b
on conflict (job_id, branch) do nothing;

/* ── 4) تنضيف الصفوف اللي ماعادت توصل ──────────────────────────── */
create or replace function public.item_expiry_prune()
returns integer language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  delete from public.item_expiry
   where synced_at < now() - interval '10 days'
      or exp_date  < current_date - interval '1 month';
  get diagnostics n = row_count;
  return n;
end
$fn$;

revoke all on function public.item_expiry_prune() from public, anon;
grant execute on function public.item_expiry_prune() to service_role;

select cron.unschedule('item_expiry_prune') where exists (
  select 1 from cron.job where jobname = 'item_expiry_prune');
select cron.schedule('item_expiry_prune', '40 2 * * *', 'select public.item_expiry_prune()');
