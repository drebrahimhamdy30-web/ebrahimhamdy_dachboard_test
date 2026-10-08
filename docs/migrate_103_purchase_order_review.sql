-- migrate_103_purchase_order_review.sql
-- تبويب «مراجعة المشتريات» — الجزء الثاني: مطابقة أمر التوريد بالفاتورة.
-- أمر التوريد = اللينك اللي بنبعته للمورّد (supplier_links). المورّد بيعلّم على المتاح عنده
-- فيترجّع في العمود reply [{b:اسم الفرع بالعربي, c:كود الصنف عندنا}] ويتعمله applied_at عند الاعتماد.
-- بنقارن اللي وصل فعلاً (purchase_invoice_items) بالمعتمد — لكل فرع على حدة — ونطلّع:
--   received_not_ordered: دخل مش طالب (مع المعدل/الرصيد/الصلاحية لقرار الإرجاع)
--   ordered_not_received: طلبته وموصلش
--   invoices_without_order: فواتير بلا أمر توريد معتمد (مورّد اشتغل بدون لينك)
-- كل فاتورة تُربط بآخر أمر معتمد لنفس المورّد تاريخه <= تاريخ الفاتورة.
-- يُطبّق على القاعدتين (الذاتي + السحابة).

create or replace function public.get_purchase_order_review(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_recv jsonb; v_miss jsonb; v_noorder integer;
begin
  -- دخل مش طالب: بنود الفاتورة مش في المعتمد (reply) لنفس الفرع
  with br(code,ar) as (values ('mamora','المعمورة'),('san','سان ستيفانو'),('bishr','سيدى بشر'),('seyouf','السيوف')),
  inv as (
    select h.branch, h.pth_id, h.ven_name_ar, h.ven_bill_date, h.entered_by,
      (select sl.id from supplier_links sl
         where sl.applied_at is not null and replace(sl.store,' ','')=replace(h.ven_name_ar,' ','')
           and sl.applied_at::date <= h.ven_bill_date::date
         order by sl.applied_at desc limit 1) as order_id
    from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar=p_vendor)
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
           pi.itm_id, pi.itm_name, pi.qnty, pi.itm_pur_price, pi.exp_date,
           round((pi.exp_date-current_date)::numeric/30.44,1) as months_left,
           s.qty as stock,
           case i.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san when 'bishr' then cf.av_bishr when 'seyouf' then cf.av_seyouf end as rate
    from inv i
    join br on br.code=i.branch
    join purchase_invoice_items pi on pi.branch=i.branch and pi.pth_id=i.pth_id
    left join stk s on s.brc=i.branch and s.itm_code=pi.itm_id::text
    left join consumption_flat cf on cf.code=pi.itm_id::text
    where i.order_id is not null
      and not exists (select 1 from ord_reply orr where orr.order_id=i.order_id and orr.br_ar=br.ar and orr.code=pi.itm_id::text)
    order by i.ven_bill_date desc, pi.pth_id limit 1000
  ) r;

  -- طلبته وموصلش: أصناف معتمدة (reply) في الفرع ماوصلتش
  with br(code,ar) as (values ('mamora','المعمورة'),('san','سان ستيفانو'),('bishr','سيدى بشر'),('seyouf','السيوف')),
  inv as (
    select h.branch, h.pth_id, h.ven_bill_date, h.ven_name_ar,
      (select sl.id from supplier_links sl
         where sl.applied_at is not null and replace(sl.store,' ','')=replace(h.ven_name_ar,' ','')
           and sl.applied_at::date <= h.ven_bill_date::date
         order by sl.applied_at desc limit 1) as order_id
    from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar=p_vendor)
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
  ),
  recv as (
    select i.order_id, br.ar br_ar, pi.itm_id::text code
    from inv i join br on br.code=i.branch
    join purchase_invoice_items pi on pi.branch=i.branch and pi.pth_id=i.pth_id
    where i.order_id is not null
  ),
  ord_reply as (
    select sl.id order_id, (r->>'b') br_ar, (r->>'c') code
    from supplier_links sl, jsonb_array_elements(sl.reply) r
    where sl.id in (select distinct order_id from inv where order_id is not null)
  )
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_miss from (
    select (select br.code from br where br.ar=orr.br_ar) as branch, orr.br_ar, orr.order_id, orr.code as itm_id,
           (select it->>'name' from supplier_links sl, jsonb_array_elements(sl.items) it where sl.id=orr.order_id and (it->>'code')=orr.code limit 1) as itm_name,
           (select it->>'qty' from supplier_links sl, jsonb_array_elements(sl.items) it where sl.id=orr.order_id and (it->>'code')=orr.code limit 1) as qty_ordered
    from (select distinct order_id, br_ar, code from ord_reply) orr
    where not exists (select 1 from recv rc where rc.order_id=orr.order_id and rc.br_ar=orr.br_ar and rc.code=orr.code)
      and (p_branch is null or p_branch='' or orr.br_ar = (select ar from br where code=p_branch))
    limit 1000
  ) r;

  -- فواتير بلا أمر توريد معتمد
  select count(*) into v_noorder from purchase_invoices h
    where (p_branch is null or p_branch='' or h.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar=p_vendor)
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
      and not exists (select 1 from supplier_links sl where sl.applied_at is not null
          and replace(sl.store,' ','')=replace(h.ven_name_ar,' ','') and sl.applied_at::date <= h.ven_bill_date::date);

  return jsonb_build_object('received_not_ordered', v_recv, 'ordered_not_received', v_miss, 'invoices_without_order', v_noorder);
end$$;

grant execute on function public.get_purchase_order_review(text,text,date,date) to anon, authenticated;
notify pgrst, 'reload schema';
