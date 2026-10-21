/* ============================================================
   مراجعة معاملات الفيزا في الشيفت الحالي
   ------------------------------------------------------------
   موظف الشيفت بيأكّد إن المعاملة **وصلت فعلًا** (المحفظة استلمت، أو
   السحب على الماكينة تم). أول ما يضغط «تم» السطر **يتقفل**: «قيمة
   المدفوع» و«الحساب» ما يتعدّلوش، ويتسجّل مين راجع وإمتى.

   ⚠️ النقطة الجوهرية: تعديل «الحساب»/«قيمة المدفوع» في الشاشة كان
   **للعرض بس وبيضيع مع أول تحديث** — مكانش بيتحفظ في أي مكان. القفل
   مالوش معنى من غير حفظ، فالمراجعة بتثبّت القيمتين **عندنا** (مش في
   eplus — هو للقراءة فقط).

   المفتاح (branch, fh_id): fh_id هو رقم الحركة في eplus وبيتزامن في
   cashier_transactions، فالمراجعة بتفضل مربوطة بالحركة الصح حتى لو
   اتعاد سحب البيانات.
   ============================================================ */

create table if not exists public.shift_txn_reviews (
  branch      text        not null,
  fh_id       bigint      not null,
  paid        numeric,                    -- القيمة المؤكَّدة وقت المراجعة
  channel     text,                       -- القناة المؤكَّدة (null = كاش)
  reviewed_by text        not null,
  reviewed_at timestamptz not null default now(),
  primary key (branch, fh_id)
);

alter table public.shift_txn_reviews enable row level security;
drop policy if exists shift_txn_reviews_read on public.shift_txn_reviews;
create policy shift_txn_reviews_read on public.shift_txn_reviews
  for select to authenticated using (true);

/* ⚠️ الكتابة بالدوال بس — PUBLIC بياخد صلاحيات افتراضية فلازم السحب
   الصريح، وanon مالوش أي علاقة بالجدول ده. */
revoke all on public.shift_txn_reviews from public, anon, authenticated;
grant select on public.shift_txn_reviews to authenticated;

/* ── مين يراجع: نفس من يفتح الشاشة ─────────────────────────────
   مش قائمة أدوار مكتوبة بالإيد — مربوطة بصلاحية الصفحة نفسها، فلو
   المالك فتح الشاشة لدور جديد يقدر يراجع من غير تعديل كود. */
create or replace function public.shift_can_review()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jwt_app_role(),'') = 'admin'
      or exists (select 1 from page_permissions p
                  where p.role = jwt_app_role()
                    and p.page_key = 'current_shift'
                    and p.can_view);
$$;

revoke all on function public.shift_can_review() from public, anon;
grant execute on function public.shift_can_review() to authenticated;

/* ── تسجيل المراجعة ──────────────────────────────────────────── */
create or replace function public.review_shift_txn(
  p_branch  text,
  p_fh_id   bigint,
  p_paid    numeric default null,
  p_channel text    default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_by text;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;

  /* الحركة لازم تكون موجودة فعلًا — من غير الفحص ده أي رقم يتسجّل */
  if not exists (select 1 from cashier_transactions c
                  where c.branch = p_branch and c.fh_id = p_fh_id) then
    raise exception 'الحركة غير موجودة' using errcode = 'P0002';
  end if;

  /* ⚠️ المراجعة مرة واحدة: من غير الشرط ده الضغط تاني بيكتب فوق
     القيمة المؤكَّدة ويغيّر اسم المراجِع بصمت. */
  if exists (select 1 from shift_txn_reviews r
              where r.branch = p_branch and r.fh_id = p_fh_id) then
    raise exception 'تمت مراجعة هذه الحركة بالفعل' using errcode = '23505';
  end if;

  v_by := public.bank_actor();
  insert into shift_txn_reviews (branch, fh_id, paid, channel, reviewed_by)
  values (p_branch, p_fh_id, p_paid, nullif(btrim(coalesce(p_channel,'')),''), v_by);

  return jsonb_build_object('success', true, 'reviewed_by', v_by,
                            'reviewed_at', to_char(now() at time zone 'Africa/Cairo','HH24:MI'));
end $$;

/* ── فكّ القفل: الأدمن فقط ───────────────────────────────────── */
create or replace function public.unreview_shift_txn(p_branch text, p_fh_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_app_role(array['admin']);
  delete from shift_txn_reviews where branch = p_branch and fh_id = p_fh_id;
  return jsonb_build_object('success', true);
end $$;

revoke all on function public.review_shift_txn(text,bigint,numeric,text)   from public, anon;
revoke all on function public.unreview_shift_txn(text,bigint)              from public, anon;
grant execute on function public.review_shift_txn(text,bigint,numeric,text) to authenticated;
grant execute on function public.unreview_shift_txn(text,bigint)            to authenticated;

/* ── get_current_shift: fh_id + حالة المراجعة مع كل حركة ───────
   ترقيع للنسخة الموجودة (زي migrate_151) — القاعدتين مش على نفس
   إصدار الدالة ونسخة كاملة هنا ممكن ترجّع واحدة منهم لورا. */
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_current_shift';

  if v_src is null then
    raise notice 'get_current_shift غير موجودة — تخطّي.';
    return;
  end if;
  if position('shift_txn_reviews' in v_src) > 0 then
    raise notice 'حالة المراجعة مضافة بالفعل — لا تغيير.';
    return;
  end if;
  if position('jsonb_build_object(''time'',to_char(actual_date,''HH24:MI'')' in v_src) = 0 then
    raise exception 'لم يُعثر على بناء صف الحركة في get_current_shift — راجع الدالة يدويًا.';
  end if;

  v_src := replace(v_src,
    'jsonb_build_object(''time'',to_char(actual_date,''HH24:MI'')',
    'jsonb_build_object(''fh_id'',fh_id,''rv'',(select jsonb_build_object(' ||
      '''by'',r.reviewed_by,''at'',to_char(r.reviewed_at at time zone ''Africa/Cairo'',''HH24:MI''),' ||
      '''paid'',r.paid,''channel'',r.channel) ' ||
      'from public.shift_txn_reviews r where r.branch = p_branch and r.fh_id = t.fh_id),' ||
      '''time'',to_char(actual_date,''HH24:MI'')');

  execute v_src;
  raise notice 'تمت إضافة fh_id وحالة المراجعة إلى get_current_shift.';
end $$;
