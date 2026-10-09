-- migrate_110_store_alias.sql
-- إصلاح: أسماء المخازن في أوامر التوريد (supplier_links.store) مختلفة عن أسماء الموردين
-- في فواتير الشراء (eplus ven_name_ar). مثال: أمر «هيلث» ≠ فاتورة «هيلث مخزن»،
-- وأوامر «ماك ميامى»/«ماك سموحه» ≠ فاتورة «ماك فارما». فكانت أصناف هيلث/ماك بتتخطى في المراجعة.
-- الحل: جدول مرادفات (order_store→invoice_vendor) + دالة po_store_match، واختيار أمر التوريد
-- بقى يشترط إن الفرع موجود في الرد (reply.b) عشان يفرّق بين ماك ميامى (معمورة/بشر) وماك سموحه (سان/سيوف).
-- يُطبّق على القاعدتين.

create table if not exists public.supplier_store_alias (
  order_store    text not null,     -- الاسم في أمر التوريد (supplier_links.store)
  invoice_vendor text not null,     -- الاسم في فاتورة الشراء (purchase_invoices.ven_name_ar)
  primary key (order_store, invoice_vendor)
);
alter table public.supplier_store_alias enable row level security;
drop policy if exists p_read on public.supplier_store_alias;
create policy p_read on public.supplier_store_alias for select to anon, authenticated using (true);
grant select on public.supplier_store_alias to anon, authenticated;
grant all on public.supplier_store_alias to service_role;

insert into public.supplier_store_alias(order_store, invoice_vendor) values
  ('هيلث','هيلث مخزن'),
  ('ماك ميامى','ماك فارما'),
  ('ماك سموحه','ماك فارما')
on conflict do nothing;

-- مطابقة اسم مخزن الأمر باسم مورّد الفاتورة: مطابقة حرفية (بعد إزالة المسافات) أو عبر المرادفات
create or replace function public.po_store_match(p_order text, p_inv text)
returns boolean language sql stable security definer set search_path=public as $$
  select replace(coalesce(p_order,''),' ','')=replace(coalesce(p_inv,''),' ','')
      or exists (select 1 from public.supplier_store_alias a
                 where replace(a.order_store,' ','')=replace(coalesce(p_order,''),' ','')
                   and replace(a.invoice_vendor,' ','')=replace(coalesce(p_inv,''),' ',''));
$$;

-- اسم الفرع بالعربي (نفس صيغة reply.b)
create or replace function public.br_ar(p_code text)
returns text language sql immutable as $$
  select case p_code when 'mamora' then 'المعمورة' when 'san' then 'سان ستيفانو'
                     when 'bishr' then 'سيدى بشر' when 'seyouf' then 'السيوف' end;
$$;

-- get_purchase_order_review: المطابقة بالمرادفات + اختيار الأمر اللي فيه الفرع
create or replace function public.get_purchase_order_review(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_recv jsonb; v_miss jsonb; v_noorder integer; v_uncoded integer;
begin
  with br(code,ar) as (values ('mamora','المعمورة'),('san','سان ستيفانو'),('bishr','سيدى بشر'),('seyouf','السيوف')),
  inv as (
    select h.branch, h.pth_id, h.ven_name_ar, h.ven_bill_date, h.entered_by,
      (select sl.id from supplier_links sl
         where sl.applied_at is not null and po_store_match(sl.store, h.ven_name_ar)
           and sl.applied_at::date <= h.ven_bill_date::date
           and exists (select 1 from jsonb_array_elements(sl.reply) r where r->>'b' = br_ar(h.branch))
         order by sl.applied_at desc limit 1) as order_id
    from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar ilike '%'||p_vendor||'%')
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
  ),
  ord_reply as (
    select sl.id order_id, (r->>'b') br_ar, (r->>'c') code
    from supplier_links sl, jsonb_array_elements(sl.reply) r
    where sl.id in (select order_id from inv where order_id is not null)
  ),
  stk as (
    select 'mamora'::text brc, itm_code, sto_qty_big qty from stock_mamora
    union all select 'bishr', itm_code, sto_qty_big from stock_bishr
    union all select 'san', itm_code, sto_qty_big from stock_san
    union all select 'seyouf', itm_code, sto_qty_big from stock_seyouf
  )
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_recv from (
    select i.branch, i.pth_id, i.ven_name_ar, i.ven_bill_date, i.entered_by,
           pi.itm_code, pi.itm_name, pi.qnty, pi.itm_pur_price, pi.exp_date,
           round((pi.exp_date-current_date)::numeric/30.44,1) as months_left,
           s.qty as stock,
           case i.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san when 'bishr' then cf.av_bishr when 'seyouf' then cf.av_seyouf end as rate
    from inv i
    join br on br.code=i.branch
    join purchase_invoice_items pi on pi.branch=i.branch and pi.pth_id=i.pth_id
    left join stk s on s.brc=i.branch and s.itm_code=pi.itm_code
    left join consumption_flat cf on cf.code=pi.itm_code
    where i.order_id is not null and pi.itm_code is not null
      and not exists (select 1 from ord_reply orr where orr.order_id=i.order_id and orr.br_ar=br.ar and orr.code=pi.itm_code)
    order by i.ven_bill_date desc, pi.pth_id limit 1000
  ) r;

  with br(code,ar) as (values ('mamora','المعمورة'),('san','سان ستيفانو'),('bishr','سيدى بشر'),('seyouf','السيوف')),
  inv as (
    select h.branch, h.pth_id, h.ven_bill_date, h.ven_name_ar,
      (select sl.id from supplier_links sl
         where sl.applied_at is not null and po_store_match(sl.store, h.ven_name_ar)
           and sl.applied_at::date <= h.ven_bill_date::date
           and exists (select 1 from jsonb_array_elements(sl.reply) r where r->>'b' = br_ar(h.branch))
         order by sl.applied_at desc limit 1) as order_id
    from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar ilike '%'||p_vendor||'%')
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
  ),
  recv as (
    select i.order_id, br.ar br_ar, pi.itm_code code
    from inv i join br on br.code=i.branch
    join purchase_invoice_items pi on pi.branch=i.branch and pi.pth_id=i.pth_id
    where i.order_id is not null and pi.itm_code is not null
  ),
  ord_reply as (
    select sl.id order_id, (r->>'b') br_ar, (r->>'c') code
    from supplier_links sl, jsonb_array_elements(sl.reply) r
    where sl.id in (select distinct order_id from inv where order_id is not null)
  ),
  stk2 as (
    select 'mamora'::text brc, itm_code, sto_qty_big qty from stock_mamora
    union all select 'bishr', itm_code, sto_qty_big from stock_bishr
    union all select 'san', itm_code, sto_qty_big from stock_san
    union all select 'seyouf', itm_code, sto_qty_big from stock_seyouf
  )
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_miss from (
    select (select br.code from br where br.ar=orr.br_ar) as branch, orr.br_ar, orr.order_id, orr.code as itm_code,
           (select sl.store from supplier_links sl where sl.id=orr.order_id) as store,
           (select it->>'name' from supplier_links sl, jsonb_array_elements(sl.items) it where sl.id=orr.order_id and (it->>'code')=orr.code limit 1) as itm_name,
           (select it->>'qty' from supplier_links sl, jsonb_array_elements(sl.items) it where sl.id=orr.order_id and (it->>'code')=orr.code limit 1) as qty_ordered,
           (select s.qty from stk2 s where s.brc=(select br.code from br where br.ar=orr.br_ar) and s.itm_code=orr.code) as stock
    from (select distinct order_id, br_ar, code from ord_reply) orr
    where not exists (select 1 from recv rc where rc.order_id=orr.order_id and rc.br_ar=orr.br_ar and rc.code=orr.code)
      and (p_branch is null or p_branch='' or orr.br_ar = (select ar from br where code=p_branch))
      and exists (select 1 from br where br.ar=orr.br_ar)
      and nullif(trim(orr.code),'') is not null
    limit 1000
  ) r;

  select count(*) into v_noorder from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar ilike '%'||p_vendor||'%')
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
      and not exists (select 1 from supplier_links sl where sl.applied_at is not null
          and po_store_match(sl.store, h.ven_name_ar) and sl.applied_at::date <= h.ven_bill_date::date
          and exists (select 1 from jsonb_array_elements(sl.reply) r where r->>'b' = br_ar(h.branch)));

  select count(*) into v_uncoded
  from purchase_invoices h
  join purchase_invoice_items pi on pi.branch=h.branch and pi.pth_id=h.pth_id
  where pi.itm_code is null
    and (p_branch is null or p_branch='' or h.branch=p_branch)
    and (p_vendor is null or p_vendor='' or h.ven_name_ar ilike '%'||p_vendor||'%')
    and (p_from is null or h.ven_bill_date >= p_from)
    and (p_to is null or h.ven_bill_date < p_to + 1)
    and exists (select 1 from supplier_links sl where sl.applied_at is not null
        and po_store_match(sl.store, h.ven_name_ar) and sl.applied_at::date <= h.ven_bill_date::date
        and exists (select 1 from jsonb_array_elements(sl.reply) r where r->>'b' = br_ar(h.branch)));

  return jsonb_build_object('received_not_ordered', v_recv, 'ordered_not_received', v_miss,
                            'invoices_without_order', v_noorder, 'uncoded_lines', v_uncoded);
end$$;
grant execute on function public.get_purchase_order_review(text,text,date,date) to anon, authenticated;
notify pgrst, 'reload schema';
