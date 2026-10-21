/* ============================================================
   «حسابات الموردين ٢ — تقفيل المطالبات»: كل فرع يشوف فرعه
   ------------------------------------------------------------
   الشاشة كانت بتعرض كل الفروع للكل، ودوالها بتقبل أي فرع العميل
   يبعته — **وممنوحة لـanon**، والمفتاح العام منشور مع الصفحة. يعني
   إخفاء القائمة في الواجهة وحده مكانش هيمنع حاجة.

   نفس أسلوب شاشات المشتريات (`purchase_branch_scope`): الأصل بيتسمّى
   `<name>_impl` ويتقفل تمامًا، والغلاف بنفس الاسم والتوقيع بيمرّر
   الفرع على الحارس — **من غير ما جسم أي دالة يتلمس**.

   الحارس بيقرا `page_permissions.all_branches` لصفحة `supplier_claims`:
   الأدمن والمراجع «كل الفروع»، ومدير الفرع فرعه بس. القيم موجودة
   بالفعل — الترحيل ده بيخلّيها **نافذة**.

   ⚠️ الدالتان اللتان تأخذان `p_id` فقط (تفاصيل المطالبة وإلغاء
   الإغلاق) ليس لهما فرع في المدخلات، فالحارس يقارن **فرع المطالبة
   نفسها** بنطاق المستخدم — بدون ذلك الرقم المتسلسل يكفي لقراءة
   مطالبة فرع آخر.
   ============================================================ */

/* ── ١) إعادة تسمية الأصل وقفله (مرة واحدة) ─────────────────── */
do $$
declare r record; v_sig text;
begin
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('get_supplier_open','get_supplier_claims',
                         'get_supplier_balance_review','close_supplier_claim',
                         'get_claim_detail','reopen_supplier_claim')
  loop
    if exists (select 1 from pg_proc p2 join pg_namespace n2 on n2.oid = p2.pronamespace
                where n2.nspname = 'public' and p2.proname = r.proname || '_impl') then
      raise notice 'الغلاف موجود بالفعل: %', r.proname;
      continue;
    end if;
    v_sig := format('public.%I(%s)', r.proname, r.args);
    execute format('alter function %s rename to %I', v_sig, r.proname || '_impl');
    execute format('revoke all on function public.%I(%s) from public, anon, authenticated',
                   r.proname || '_impl', r.args);
  end loop;
end $$;

/* ── ٢) الأغلفة ─────────────────────────────────────────────── */
create or replace function public.get_supplier_open(
  p_branch text, p_vendor text, p_from date, p_to date
) returns jsonb language sql stable security definer set search_path = public as $$
  select public.get_supplier_open_impl(
           public.purchase_branch_scope(p_branch, 'supplier_claims'), p_vendor, p_from, p_to);
$$;

create or replace function public.get_supplier_claims(
  p_branch text, p_vendor text
) returns setof public.supplier_claims language sql stable security definer set search_path = public as $$
  select * from public.get_supplier_claims_impl(
           public.purchase_branch_scope(p_branch, 'supplier_claims'), p_vendor);
$$;

create or replace function public.get_supplier_balance_review(
  p_branch text, p_min_diff numeric
) returns jsonb language sql stable security definer set search_path = public as $$
  select public.get_supplier_balance_review_impl(
           public.purchase_branch_scope(p_branch, 'supplier_claims'), p_min_diff);
$$;

create or replace function public.close_supplier_claim(
  p_branch text, p_vendor text, p_inv jsonb, p_ret jsonb,
  p_local numeric, p_pct numeric, p_note text, p_from date, p_to date
) returns jsonb language sql volatile security definer set search_path = public as $$
  select public.close_supplier_claim_impl(
           coalesce(public.purchase_branch_scope(p_branch, 'supplier_claims'), p_branch),
           p_vendor, p_inv, p_ret, p_local, p_pct, p_note, p_from, p_to);
$$;

/* ── ٣) حارس المطالبة بالرقم ────────────────────────────────── */
create or replace function public.claim_in_scope(p_id bigint)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_br text; v_scope text;
begin
  select branch into v_br from supplier_claims where id = p_id;
  if v_br is null then
    raise exception 'المطالبة غير موجودة' using errcode = 'P0002';
  end if;
  v_scope := public.purchase_branch_scope(null, 'supplier_claims');  -- null = كل الفروع
  if v_scope is not null and v_scope <> v_br then
    raise exception 'هذه المطالبة تخص فرعًا آخر' using errcode = '42501';
  end if;
end $$;

create or replace function public.get_claim_detail(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.claim_in_scope(p_id);
  return public.get_claim_detail_impl(p_id);
end $$;

create or replace function public.reopen_supplier_claim(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.claim_in_scope(p_id);
  return public.reopen_supplier_claim_impl(p_id);
end $$;

/* ── ٤) الصلاحيات: المستخدم المسجَّل فقط ─────────────────────
   ⚠️ أي دالة جديدة بتاخد EXECUTE لـPUBLIC افتراضيًا — السحب الصريح
   إلزامي، وإلا الغلاف نفسه يبقى مفتوح لمفتاح anon زي ما كان الأصل. */
do $$
declare r record;
begin
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('get_supplier_open','get_supplier_claims',
                         'get_supplier_balance_review','close_supplier_claim',
                         'get_claim_detail','reopen_supplier_claim','claim_in_scope')
  loop
    execute format('revoke all on function public.%I(%s) from public, anon', r.proname, r.args);
    execute format('grant execute on function public.%I(%s) to authenticated', r.proname, r.args);
  end loop;
end $$;
