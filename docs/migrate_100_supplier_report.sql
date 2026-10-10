/* ============================================================
   تقرير الموردين — تبويب في شاشة فواتير الشراء
   ------------------------------------------------------------
   الربح هنا **حقيقي مش تقديري**: كل سطر شراء فيه itm_pur_price
   (التكلفة) و itm_sell (سعر البيع)، والاتنين متملّيين في كل الـ63
   ألف سطر. الربح المتوقع = (الكمية + البونص) × سعر البيع − قيمة
   الفاتورة، فالبونص بيتحسب ربح زي ما هو فعلًا.
   وده ربح **الصفقة وقت الشراء** مش ربح محقّق — بيتحقق عند البيع.

   «فرق سعر ضائع»: لكل صنف بنجيب أرخص تكلفة وحدة كانت متاحة في نفس
   الفترة من أي مورّد، والفرق × الكمية = اللي كان ممكن يتوفّر.
   التكلفة بتتحسب على (الإجمالي ÷ الكمية + البونص) عشان صفقات البونص
   تتقارن بعدل مع الخصم النقدي.

   ⚠️ فيه 2042 سطر (~مليون جنيه) من غير كود **ولا اسم**. دول:
     • محتسبين في إجماليات المورّد والملخّص (فلوس اتدفعت فعلًا)
     • مستبعدين من جداول الأصناف، لأنهم بيتجمّعوا في مجموعة واحدة
       فتتقارن أصناف مالهاش علاقة ببعض وتطلع «فرص توفير» وهمية،
       ومفيش تصرّف ممكن يتاخد على صنف مش معروف أصلًا.

   الصلاحية: الشاشة بتنادي الدالة بـrpcAuth (توكن المستخدم) مش
   بالمفتاح العام، لأن التقرير بيكشف تكاليف الشراء وهوامش الربح
   والمفتاح العام منشور مع الصفحة.
   ============================================================ */
create or replace function public.get_supplier_report(
  p_from date, p_to date, p_branch text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v jsonb;
begin
  if p_from is null or p_to is null then return '{}'::jsonb; end if;

  with l as (
    select h.ven_name_ar as ven, h.branch, h.pth_id,
           nullif(i.itm_code,'') as itm_code, nullif(i.itm_name,'') as itm_name,
           i.qnty, coalesce(i.bonus,0) as bonus,
           i.itm_pur_price, i.itm_sell, i.line_total, i.exp_date,
           coalesce(i.itm_back_qty,0) as back_qty,
           (h.ven_bill_date)::date as d,
           (i.qnty + coalesce(i.bonus,0)) * i.itm_sell as sell_val,
           case when i.qnty + coalesce(i.bonus,0) > 0
                then i.line_total / (i.qnty + coalesce(i.bonus,0)) end as unit_cost,
           coalesce(nullif(i.itm_code,''), nullif(i.itm_name,'')) as key
      from purchase_invoice_items i
      join purchase_invoices h on h.branch = i.branch and h.pth_id = i.pth_id
     where (h.ven_bill_date)::date between p_from and p_to
       and coalesce(h.ven_name_ar,'') <> ''
       and coalesce(i.line_total,0) > 0
       and (p_branch is null or p_branch = '' or h.branch = p_branch)
  ),
  best as (   /* أرخص تكلفة وحدة + **مين** باعها بالسعر ده وإمتى */
    select distinct on (key)
           key, unit_cost as min_cost, ven as best_ven, d as best_d
      from l
     where unit_cost is not null and key is not null
     order by key, unit_cost asc, d desc
  ),
  ln as (
    select l.*, b.min_cost, b.best_ven, b.best_d,
           case when l.key is not null and l.unit_cost is not null
                     and b.min_cost is not null and l.unit_cost > b.min_cost
                then (l.unit_cost - b.min_cost) * (l.qnty + l.bonus) end as lost
      from l left join best b on b.key = l.key
  ),
  ven as (
    select ven,
           count(distinct (branch, pth_id))                       as bills,
           count(distinct key)                                    as items,
           sum(line_total)                                        as buy,
           sum(sell_val)                                          as sell,
           sum(sell_val) - sum(line_total)                        as profit,
           sum(bonus * itm_sell)                                  as bonus_val,
           sum(back_qty * itm_pur_price)                          as back_val,
           sum(line_total) filter (
             where exp_date is not null and exp_date < d + interval '6 months') as short_exp,
           coalesce(sum(lost), 0)                                 as lost
      from ln group by ven
  ),
  tot as (select sum(buy) b, sum(sell) s, sum(profit) p, sum(bills) bl,
                 count(*) n, coalesce(sum(lost),0) lo from ven)
  select jsonb_build_object(
    'summary', (select jsonb_build_object(
        'buy', round(coalesce(b,0)), 'sell', round(coalesce(s,0)),
        'profit', round(coalesce(p,0)),
        'margin', case when coalesce(s,0) > 0 then round(100*p/s, 1) else 0 end,
        'bills', coalesce(bl,0), 'vendors', coalesce(n,0),
        'lost', round(coalesce(lo,0))) from tot),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object(
        'ven', ven, 'bills', bills, 'items', items,
        'buy', round(buy), 'profit', round(profit),
        'margin', case when sell > 0 then round(100*profit/sell, 1) else 0 end,
        'share', case when (select b from tot) > 0
                      then round(100*buy/(select b from tot), 1) else 0 end,
        'avg_bill', case when bills > 0 then round(buy/bills) else 0 end,
        'bonus', round(bonus_val), 'back', round(back_val),
        'short_exp', round(coalesce(short_exp,0)), 'lost', round(lost))
        order by profit desc), '[]'::jsonb) from ven),
    'savings', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object('ven', ven, 'code', max(itm_code),
                 'name', max(itm_name), 'qty', round(sum(qnty+bonus),2),
                 'paid', round(max(unit_cost),2), 'best', round(max(min_cost),2),
                 'best_ven', max(best_ven), 'best_d', max(best_d),
                 'lost', round(sum(lost))) as x
          from ln where lost > 0 and key is not null
         group by ven, key
         order by sum(lost) desc limit 20) y),
    'top_items', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object('code', max(itm_code), 'name', max(itm_name),
                 'buy', round(sum(line_total)),
                 'profit', round(sum(sell_val) - sum(line_total)),
                 'margin', case when sum(sell_val) > 0
                      then round(100*(sum(sell_val)-sum(line_total))/sum(sell_val), 1) else 0 end,
                 'ven', (array_agg(ven order by line_total desc))[1]) as x
          from ln where key is not null group by key
         order by sum(line_total) desc limit 20) z)
  ) into v;

  return coalesce(v, '{}'::jsonb);
end
$fn$;

revoke all on function public.get_supplier_report(date, date, text) from public, anon;
grant execute on function public.get_supplier_report(date, date, text) to authenticated;

notify pgrst, 'reload schema';
