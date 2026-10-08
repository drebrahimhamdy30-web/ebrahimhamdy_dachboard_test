-- migrate_101_purchase_invoices_view.sql
-- شاشة «فواتير الشراء» (purchase_invoices.html): دوال عرض القائمة + تفاصيل الفاتورة + أسماء الموردين للفلتر.
-- المجاميع والترقيم بيتحسبوا في القاعدة (jsonb صف واحد) — مش في المتصفح. يُطبّق على القاعدتين.

-- قائمة الفواتير: صفحة + مجاميع على كل المفلتر
create or replace function public.get_purchases(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null,
  p_search text default null, p_page integer default 1, p_page_size integer default 40
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  off integer := greatest(coalesce(p_page,1)-1,0) * coalesce(p_page_size,40);
  v_total bigint; v_value numeric; v_paid numeric; v_back numeric; v_rows jsonb;
begin
  select count(*), coalesce(sum(total_bill),0), coalesce(sum(pth_paid),0), coalesce(sum(total_after_back),0)
    into v_total, v_value, v_paid, v_back
  from purchase_invoices h
  where (p_branch is null or p_branch='' or h.branch=p_branch)
    and (p_vendor is null or p_vendor='' or h.ven_name_ar=p_vendor)
    and (p_from is null or h.ven_bill_date >= p_from)
    and (p_to is null or h.ven_bill_date < p_to + 1)
    and (p_search is null or p_search='' or h.ven_bill_no ilike '%'||p_search||'%' or h.ven_name_ar ilike '%'||p_search||'%' or cast(h.pth_id as text) like p_search||'%');
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_rows from (
    select h.branch, h.pth_id, h.ven_bill_no, h.ven_bill_date, h.ven_name_ar, h.sto_id, h.store_name,
           h.no_of_items, h.total_bill, h.total_des_mon, h.pth_paid, h.total_after_back, h.bill_status, h.entered_by
    from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar=p_vendor)
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
      and (p_search is null or p_search='' or h.ven_bill_no ilike '%'||p_search||'%' or h.ven_name_ar ilike '%'||p_search||'%' or cast(h.pth_id as text) like p_search||'%')
    order by h.ven_bill_date desc nulls last, h.pth_id desc
    limit coalesce(p_page_size,40) offset off
  ) r;
  return jsonb_build_object('total',v_total,'total_value',v_value,'total_paid',v_paid,'total_after_back',v_back,'rows',v_rows);
end$$;

-- تفاصيل فاتورة (رأس + بنود)
create or replace function public.get_purchase_invoice(p_branch text, p_pth_id bigint)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_h jsonb; v_items jsonb;
begin
  select to_jsonb(h) into v_h from purchase_invoices h where h.branch=p_branch and h.pth_id=p_pth_id;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.ptd_id),'[]'::jsonb) into v_items
  from purchase_invoice_items i where i.branch=p_branch and i.pth_id=p_pth_id;
  return jsonb_build_object('header',v_h,'items',v_items);
end$$;

-- أسماء الموردين (للفلتر)
create or replace function public.get_purchase_vendor_names(p_branch text default null)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(v order by v),'[]'::jsonb) from (
    select distinct ven_name_ar v from purchase_invoices
    where ven_name_ar is not null and ven_name_ar<>'' and (p_branch is null or p_branch='' or branch=p_branch)
  ) t;
$$;

grant execute on function public.get_purchases(text,text,date,date,text,integer,integer) to anon, authenticated;
grant execute on function public.get_purchase_invoice(text,bigint) to anon, authenticated;
grant execute on function public.get_purchase_vendor_names(text) to anon, authenticated;

-- تسجيل الشاشة
INSERT INTO app_pages (key, file, title, section, sort_order, is_active)
VALUES ('purchase_invoices','purchase_invoices.html','فواتير الشراء','المشتريات والموردين',416,true)
ON CONFLICT (key) DO UPDATE SET file=excluded.file, title=excluded.title, section=excluded.section, sort_order=excluded.sort_order, is_active=true;

INSERT INTO page_permissions (page, role, can_view, can_edit, page_key, sort_order)
SELECT 'purchase_invoices.html', r,
       r in ('admin','manager','accountant','pharmacist','inventory','reviewer'),
       r in ('admin','manager'),
       'purchase_invoices', 1
  FROM unnest(array['admin','manager','employee','pharmacist','cashier','accountant','reviewer','inventory','supervisor']) r
 WHERE NOT EXISTS (SELECT 1 FROM page_permissions WHERE page_key='purchase_invoices' AND role=r);

notify pgrst, 'reload schema';
