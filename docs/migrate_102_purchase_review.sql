-- migrate_102_purchase_review.sql
-- تبويب «مراجعة المشتريات» — الجزء الأول: تنبيه الصلاحية والمرتجعات.
-- الأصناف قريبة الصلاحية في فواتير الشراء، مع: المورّد، الموظف اللي أدخل الفاتورة،
-- الرصيد (stock_<فرع>.sto_qty_big)، والمعدل الشهري (consumption_flat.av_<فرع>) — لاتخاذ قرار الإرجاع.
-- يُطبّق على القاعدتين. (جزء مطابقة أمر التوريد supplier_links هييجي في ترحيل تالي.)

create or replace function public.get_purchase_expiry_review(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null, p_months integer default 6
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v jsonb;
begin
  with stk as (
    select 'mamora'::text br, itm_code, sto_qty_big qty from stock_mamora
    union all select 'bishr', itm_code, sto_qty_big from stock_bishr
    union all select 'san',   itm_code, sto_qty_big from stock_san
    union all select 'seyouf',itm_code, sto_qty_big from stock_seyouf
  )
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v from (
    select pi.branch, pi.pth_id, h.ven_name_ar, h.ven_bill_date, h.entered_by,
           pi.itm_id, pi.itm_name, pi.qnty, pi.itm_pur_price, pi.exp_date,
           round((pi.exp_date - current_date)::numeric / 30.44, 1) as months_left,
           s.qty as stock,
           case pi.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san
                          when 'bishr' then cf.av_bishr when 'seyouf' then cf.av_seyouf end as rate
    from purchase_invoice_items pi
    join purchase_invoices h on h.branch=pi.branch and h.pth_id=pi.pth_id
    left join stk s on s.br=pi.branch and s.itm_code=pi.itm_id::text
    left join consumption_flat cf on cf.code=pi.itm_id::text
    where pi.exp_date is not null
      and pi.exp_date < (current_date + make_interval(months => p_months))
      and (p_branch is null or p_branch='' or pi.branch=p_branch)
      and (p_vendor is null or p_vendor='' or h.ven_name_ar=p_vendor)
      and (p_from is null or h.ven_bill_date >= p_from)
      and (p_to is null or h.ven_bill_date < p_to + 1)
    order by pi.exp_date asc
    limit 500
  ) r;
  return v;
end$$;

grant execute on function public.get_purchase_expiry_review(text,text,date,date,integer) to anon, authenticated;
notify pgrst, 'reload schema';
