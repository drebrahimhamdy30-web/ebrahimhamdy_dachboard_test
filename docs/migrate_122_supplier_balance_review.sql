-- migrate_122_supplier_balance_review.sql
-- مراجعة أرصدة الموردين: لكل مورّد×فرع يقارن الرصيد (eplus) بصافي المفتوح
-- (فواتير مفتوحة − مرتجعات مفتوحة) ويرجّع اللي الفرق فيهم > حد (افتراضي 5ج).
-- نفس تعريف «المفتوح» في get_supplier_open (فواتير/مرتجعات مش مقفولة في claim_*).
-- الرصيد = max(ven_current_credit) + vendor_balance_adjust.adjust.
-- يُطبّق على السحابة (فيها بيانات المشتريات). الإجماليات تُحسب على كل المطابق للحد.

create or replace function public.get_supplier_balance_review(
  p_branch text default null, p_min_diff numeric default 5)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with
  inv as (
    select h.branch, h.ven_name_ar v, sum(h.total_bill::numeric) inv_total
      from purchase_invoices h
     where (p_branch is null or h.branch = p_branch)
       and not exists (select 1 from claim_invoices c where c.branch=h.branch and c.pth_id=h.pth_id)
     group by h.branch, h.ven_name_ar),
  retb as (
    select i.branch, h.ven_name_ar v,
           sum(round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2)) rt
      from purchase_invoice_items i
      join purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
     where (p_branch is null or i.branch = p_branch) and coalesce(i.itm_back_qty,0)<>0
       and not exists (select 1 from claim_returns c where c.branch=i.branch and c.ret_kind='bill' and c.r1=i.pth_id and c.r2=i.ptd_id)
     group by i.branch, h.ven_name_ar),
  retg as (
    select r.branch, r.ven_name_ar v,
           sum(round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2)) rt
      from purchase_returns r
     where (p_branch is null or r.branch = p_branch)
       and not exists (select 1 from claim_returns c where c.branch=r.branch and c.ret_kind='gen' and c.r1=r.ibh_id and c.r2=r.ibd_id)
     group by r.branch, r.ven_name_ar),
  bal as (
    select pv.branch, pv.ven_name_ar v,
           max(pv.ven_current_credit)
         + coalesce((select adjust from vendor_balance_adjust a where a.branch=pv.branch and a.ven_name_ar=pv.ven_name_ar),0) balance
      from purchase_vendors pv
     where (p_branch is null or pv.branch = p_branch)
     group by pv.branch, pv.ven_name_ar),
  allv as (
    select branch,v from inv union select branch,v from retb
    union select branch,v from retg union select branch,v from bal),
  j as (
    select a.branch, a.v vendor,
           round(coalesce(bal.balance,0))::numeric bal_r,
           round(coalesce(inv.inv_total,0))::numeric inv_r,
           round(coalesce(retb.rt,0)+coalesce(retg.rt,0))::numeric ret_r
      from allv a
      left join inv  on inv.branch =a.branch and inv.v =a.v
      left join retb on retb.branch=a.branch and retb.v=a.v
      left join retg on retg.branch=a.branch and retg.v=a.v
      left join bal  on bal.branch =a.branch and bal.v =a.v),
  k as (
    select branch, vendor, bal_r balance, inv_r inv_total, ret_r ret_total,
           (inv_r - ret_r) open_net, (inv_r - ret_r - bal_r) diff
      from j)
  select jsonb_build_object(
    'total_count',    (select count(*) from k where abs(diff) > p_min_diff),
    'total_abs_diff', (select coalesce(sum(abs(diff)),0) from k where abs(diff) > p_min_diff),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by abs(x.diff) desc, x.vendor)
                      from (select branch, vendor, balance, inv_total, ret_total, open_net, diff
                              from k where abs(diff) > p_min_diff) x), '[]'::jsonb));
$function$;

grant execute on function public.get_supplier_balance_review(text,numeric) to anon, authenticated;
notify pgrst, 'reload schema';
