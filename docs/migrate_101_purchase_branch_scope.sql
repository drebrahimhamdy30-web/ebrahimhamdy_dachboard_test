/* ============================================================
   شاشة المشتريات: كل موظف يشوف فرعه بس — الأدمن وحده يشوف الكل
   ------------------------------------------------------------
   ليه على السيرفر مش في الواجهة:
     دوال المشتريات كانت ممنوحة لـ PUBLIC و anon، والمفتاح العام
     منشور مع الصفحة. يعني إخفاء فلتر الفرع في الشاشة مكانش هيمنع
     أي حد من نداء الدالة مباشرة بأي فرع ويشوف تكاليف الشراء
     وهوامش الربح. القيد الحقيقي لازم يبقى جوّه الدالة.

   الطريقة — غلاف مش تعديل:
     كل دالة اتسمّت <name>_impl، واتعمل غلاف بنفس الاسم والتوقيع
     بيمرّر الفرع بعد ما يعدّي على purchase_branch_scope().
     كده مفيش جسم دالة موجودة اتلمس، فمفيش خطر على منطقها، والأصل
     اتقفل تمامًا (مفيش anon ولا authenticated) فالدخول من الغلاف بس.

   ⚠️ الفرع في التوكن **اسم عربي** («المعمورة») مش كود («mamora»)،
      فالحارس بيترجمه من جدول branches بالاسم أو الاسم البديل.

   ⚠️ الحسابات اللي فرعها «عام» أو «كل الفروع» وهي مش أدمن هتترفض
      برسالة واضحة. وقت التطبيق كان فيه 3 حسابات كده (صيدلي ×2
      ومراجع ×1) ليهم صلاحية عرض الشاشة — محتاجين فرع محدّد.
   ============================================================ */
create or replace function public.purchase_branch_scope(p_branch text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := jwt_app_role();
  v_br   text := jwt_branch();
  v_code text;
begin
  if v_role = 'admin' then
    return nullif(btrim(coalesce(p_branch, '')), '');   -- فاضي = كل الفروع
  end if;
  if v_role is null then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;

  select b.code into v_code
    from branches b
   where b.name = v_br or v_br = any(coalesce(b.aliases, '{}'::text[]))
   limit 1;

  if v_code is null then
    raise exception 'حسابك غير مربوط بفرع محدّد — يُرجى مراجعة إدارة المستخدمين'
      using errcode = '42501';
  end if;
  return v_code;   -- بنتجاهل اللي العميل بعته
end
$fn$;

revoke all on function public.purchase_branch_scope(text) from public, anon;
grant execute on function public.purchase_branch_scope(text) to authenticated;

do $$
begin
  if to_regprocedure('public.get_purchases_impl(text,text,date,date,text,integer,integer)') is null then
    alter function public.get_purchases(text,text,date,date,text,integer,integer) rename to get_purchases_impl;
  end if;
  if to_regprocedure('public.get_purchase_vendor_names_impl(text)') is null then
    alter function public.get_purchase_vendor_names(text) rename to get_purchase_vendor_names_impl;
  end if;
  if to_regprocedure('public.get_purchase_expiry_review_impl(text,text,date,date,integer)') is null then
    alter function public.get_purchase_expiry_review(text,text,date,date,integer) rename to get_purchase_expiry_review_impl;
  end if;
  if to_regprocedure('public.get_purchase_order_review_impl(text,text,date,date)') is null then
    alter function public.get_purchase_order_review(text,text,date,date) rename to get_purchase_order_review_impl;
  end if;
  if to_regprocedure('public.get_purchase_surplus_return_impl(text,text,date,date,integer,integer)') is null then
    alter function public.get_purchase_surplus_return(text,text,date,date,integer,integer) rename to get_purchase_surplus_return_impl;
  end if;
  if to_regprocedure('public.get_purchase_invoice_impl(text,bigint)') is null then
    alter function public.get_purchase_invoice(text,bigint) rename to get_purchase_invoice_impl;
  end if;
  if to_regprocedure('public.get_supplier_report_impl(date,date,text)') is null then
    alter function public.get_supplier_report(date,date,text) rename to get_supplier_report_impl;
  end if;
end $$;

create or replace function public.get_purchases(
  p_branch text, p_vendor text, p_from date, p_to date,
  p_search text, p_page integer, p_page_size integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchases_impl(public.purchase_branch_scope(p_branch),
         p_vendor, p_from, p_to, p_search, p_page, p_page_size);
$$;

create or replace function public.get_purchase_vendor_names(p_branch text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_vendor_names_impl(public.purchase_branch_scope(p_branch));
$$;

create or replace function public.get_purchase_expiry_review(
  p_branch text, p_vendor text, p_from date, p_to date, p_months integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_expiry_review_impl(public.purchase_branch_scope(p_branch),
         p_vendor, p_from, p_to, p_months);
$$;

create or replace function public.get_purchase_order_review(
  p_branch text, p_vendor text, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_order_review_impl(public.purchase_branch_scope(p_branch),
         p_vendor, p_from, p_to);
$$;

create or replace function public.get_purchase_surplus_return(
  p_branch text, p_vendor text, p_from date, p_to date, p_limit integer, p_offset integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_surplus_return_impl(public.purchase_branch_scope(p_branch),
         p_vendor, p_from, p_to, p_limit, p_offset);
$$;

create or replace function public.get_purchase_invoice(p_branch text, p_pth_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_purchase_invoice_impl(public.purchase_branch_scope(p_branch), p_pth_id);
$$;

create or replace function public.get_supplier_report(
  p_from date, p_to date, p_branch text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.get_supplier_report_impl(p_from, p_to, public.purchase_branch_scope(p_branch));
$$;

/* الأصل يتقفل تمامًا — الدخول من الغلاف بس */
revoke all on function public.get_purchases_impl(text,text,date,date,text,integer,integer) from public, anon, authenticated;
revoke all on function public.get_purchase_vendor_names_impl(text) from public, anon, authenticated;
revoke all on function public.get_purchase_expiry_review_impl(text,text,date,date,integer) from public, anon, authenticated;
revoke all on function public.get_purchase_order_review_impl(text,text,date,date) from public, anon, authenticated;
revoke all on function public.get_purchase_surplus_return_impl(text,text,date,date,integer,integer) from public, anon, authenticated;
revoke all on function public.get_purchase_invoice_impl(text,bigint) from public, anon, authenticated;
revoke all on function public.get_supplier_report_impl(date,date,text) from public, anon, authenticated;

revoke all on function public.get_purchases(text,text,date,date,text,integer,integer) from public, anon;
revoke all on function public.get_purchase_vendor_names(text) from public, anon;
revoke all on function public.get_purchase_expiry_review(text,text,date,date,integer) from public, anon;
revoke all on function public.get_purchase_order_review(text,text,date,date) from public, anon;
revoke all on function public.get_purchase_surplus_return(text,text,date,date,integer,integer) from public, anon;
revoke all on function public.get_purchase_invoice(text,bigint) from public, anon;
revoke all on function public.get_supplier_report(date,date,text) from public, anon;

grant execute on function public.get_purchases(text,text,date,date,text,integer,integer) to authenticated;
grant execute on function public.get_purchase_vendor_names(text) to authenticated;
grant execute on function public.get_purchase_expiry_review(text,text,date,date,integer) to authenticated;
grant execute on function public.get_purchase_order_review(text,text,date,date) to authenticated;
grant execute on function public.get_purchase_surplus_return(text,text,date,date,integer,integer) to authenticated, service_role;
grant execute on function public.get_purchase_invoice(text,bigint) to authenticated;
grant execute on function public.get_supplier_report(date,date,text) to authenticated;

notify pgrst, 'reload schema';
