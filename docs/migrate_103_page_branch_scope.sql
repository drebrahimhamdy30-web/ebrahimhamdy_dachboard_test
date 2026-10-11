/* ============================================================
   نطاق الفروع بقى لكل (دور × شاشة) مش لكل دور
   ------------------------------------------------------------
   السبب: المحاسب محتاج «كل الفروع» في استيراد الماكينات و«فرعه بس»
   في إغلاق الشيفت. إعداد واحد للدور مايعبّرش عن ده.

   role_branch_scope بتفضل كقيمة افتراضية لأي شاشة مالهاش صف، واتزرعت
   منها القيم وقت الترقية عشان السلوك مايتغيّرش لحظة التطبيق.

   get_role_pages بترجّع النطاق مع الصلاحية، فالواجهة بتقراه من نفس
   النداء المكاش في session.js — من غير أي طلب شبكة زيادة.

   ⚠️ النسخة القديمة purchase_branch_scope(text) **لازم تتشال**: لو
   فضلت، أي نداء بوسيط واحد كان هيلزق بيها (المطابقة التامة بتكسب)
   وهي بتقرا نطاق الدور العام مش نطاق الشاشة.
   ============================================================ */
alter table public.page_permissions
  add column if not exists all_branches boolean not null default false;

update public.page_permissions p
   set all_branches = coalesce(r.all_branches, false)
  from public.role_branch_scope r
 where r.role = p.role
   and p.all_branches is distinct from coalesce(r.all_branches, false);

update public.page_permissions set all_branches = true where role = 'admin';

create or replace function public.get_role_pages(p_role text)
returns jsonb
language sql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'page',         ap.file,
    'key',          ap.key,
    'title',        ap.title,
    'section',      ap.section,
    'badge',        ap.badge,
    'can_view',     pp.can_view,
    'can_edit',     pp.can_edit,
    'all_branches', coalesce(pp.all_branches, false)
  ) order by ap.sort_order), '[]'::jsonb)
  from public.page_permissions pp
  join public.app_pages ap on ap.key = pp.page_key
  where pp.role = p_role and pp.can_view = true and ap.is_active;
$fn$;

/* حفظ منفصل عن save_page_permissions_bulk عشان مانلمسش دالة شغّالة */
create or replace function public.save_page_branch_scope(p_updates jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare n integer := 0;
begin
  perform require_app_role(array['admin']);

  update page_permissions pp
     set all_branches = coalesce((u->>'all_branches')::boolean, false)
    from jsonb_array_elements(coalesce(p_updates, '[]'::jsonb)) u
   where pp.role = u->>'role'
     and pp.page_key = u->>'page_key';
  get diagnostics n = row_count;

  update page_permissions set all_branches = true where role = 'admin';
  return n;
end
$fn$;

revoke all on function public.save_page_branch_scope(jsonb) from public, anon;
grant execute on function public.save_page_branch_scope(jsonb) to authenticated;

drop function if exists public.purchase_branch_scope(text);

create or replace function public.purchase_branch_scope(
  p_branch text, p_page text default 'purchase_invoices')
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := jwt_app_role();
  v_br   text := jwt_branch();
  v_all  boolean;
  v_code text;
begin
  if v_role is null then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  if v_role = 'admin' then
    return nullif(btrim(coalesce(p_branch, '')), '');
  end if;

  select pp.all_branches into v_all
    from page_permissions pp
   where pp.role = v_role and pp.page_key = p_page;

  if v_all is null then   -- شاشة مالهاش صف: نرجع لافتراضي الدور
    select r.all_branches into v_all from role_branch_scope r where r.role = v_role;
  end if;

  if coalesce(v_all, false) then
    return nullif(btrim(coalesce(p_branch, '')), '');
  end if;

  /* ⚠️ الفرع في التوكن اسم عربي («المعمورة») مش كود («mamora») */
  select b.code into v_code
    from branches b
   where b.name = v_br or v_br = any(coalesce(b.aliases, '{}'::text[]))
   limit 1;

  if v_code is null then
    raise exception 'حسابك غير مربوط بفرع محدّد — يُرجى مراجعة إدارة المستخدمين'
      using errcode = '42501';
  end if;
  return v_code;
end
$fn$;

revoke all on function public.purchase_branch_scope(text, text) from public, anon;
grant execute on function public.purchase_branch_scope(text, text) to authenticated;

/* الأغلفة بتبعت مفتاح الشاشة */
create or replace function public.get_purchases(
  p_branch text, p_vendor text, p_from date, p_to date,
  p_search text, p_page integer, p_page_size integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchases_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'),
           p_vendor, p_from, p_to, p_search, p_page, p_page_size);
$$;

create or replace function public.get_purchase_vendor_names(p_branch text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_vendor_names_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'));
$$;

create or replace function public.get_purchase_expiry_review(
  p_branch text, p_vendor text, p_from date, p_to date, p_months integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_expiry_review_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'),
           p_vendor, p_from, p_to, p_months);
$$;

create or replace function public.get_purchase_order_review(
  p_branch text, p_vendor text, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_order_review_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'),
           p_vendor, p_from, p_to);
$$;

create or replace function public.get_purchase_surplus_return(
  p_branch text, p_vendor text, p_from date, p_to date, p_limit integer, p_offset integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_surplus_return_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'),
           p_vendor, p_from, p_to, p_limit, p_offset);
$$;

create or replace function public.get_purchase_invoice(p_branch text, p_pth_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_invoice_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'), p_pth_id);
$$;

create or replace function public.get_supplier_report(
  p_from date, p_to date, p_branch text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_supplier_report_impl(p_from, p_to,
           public.purchase_branch_scope(p_branch, 'purchase_invoices'));
$$;

notify pgrst, 'reload schema';
