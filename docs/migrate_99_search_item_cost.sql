/* ============================================================
   بحث بالتكلفة من خانة البحث في الشريط العلوي
   ------------------------------------------------------------
   البحث بالكود أو الاسم بيرجّع آخر أسعار شراء للصنف، كل سعر
   بتاريخه ومورّده والفرع اللي اتشترى له.

   ليه التجميع بـ(تاريخ، مورّد، سعر):
     نفس الشراء بيتسجّل بفاتورة منفصلة لكل فرع، فلو عرضنا السطور
     زي ما هي «آخر 4 أسعار» بتطلع نفس السعر مكرر 4 مرات. فكل صف
     بقى **حدث سعر** حقيقي، والكميات بتتجمع والفروع بتتجمّع في قائمة.

   ليه المطابقة على قايمة الأصناف مش على السطور:
     ar_norm لكل سطر من 63 ألف سطر كانت بتوصل الدالة لـ760ms، وده
     كتير على بحث بيشتغل مع كل حرف. المطابقة بقت على الأصناف
     المميّزة (~9.8 ألف) والنتيجة 118ms.

   المصدر: purchase_invoices + purchase_invoice_items (مزامنة eplus).
   ⚠️ الجدولين دول على السحابة؛ لو السيرفر الذاتي مافيهوش المزامنة
      الشاشة بتقول «بيانات فواتير الشراء غير متاحة على هذا الخادم بعد».
   ============================================================ */

create index if not exists idx_pii_code      on public.purchase_invoice_items(itm_code);
create index if not exists idx_pii_code_name on public.purchase_invoice_items(itm_code, itm_name);
create index if not exists idx_pi_branch_pth on public.purchase_invoices(branch, pth_id);

create or replace function public.search_item_cost(
  p_q text, p_limit integer default 6, p_hist integer default 4)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_q  text := btrim(coalesce(p_q, ''));
  v_n  text;
  v_ws text[];
  v_res jsonb;
begin
  if length(v_q) < 2 then return '[]'::jsonb; end if;
  v_n := ar_norm(v_q);
  v_ws := array(select w from regexp_split_to_table(v_n, '\s+') w where length(w) > 1);
  if v_ws is null or array_length(v_ws, 1) is null then v_ws := array[v_n]; end if;

  with cand as (   /* الأصناف المميّزة بس */
    select itm_code, max(itm_name) as itm_name
      from purchase_invoice_items
     where coalesce(itm_code, '') <> ''
     group by itm_code
  ),
  m as (
    select c.itm_code, c.itm_name, (c.itm_code = v_q)::int as exact
      from cand c
     where c.itm_code = v_q
        or c.itm_code like v_q || '%'
        or (select bool_and(ar_norm(c.itm_name) like '%' || w || '%') from unnest(v_ws) w)
     limit 25
  ),
  li as (
    select i.itm_code, i.qnty, coalesce(i.bonus, 0) as bonus, i.itm_pur_price,
           coalesce(i.itm_dis_per, 0) as dis, i.line_total,
           i.branch, h.ven_name_ar, (h.ven_bill_date)::date as d
      from m
      join purchase_invoice_items i on i.itm_code = m.itm_code
      join purchase_invoices h on h.branch = i.branch and h.pth_id = i.pth_id
     where coalesce(i.itm_pur_price, 0) > 0
  ),
  g as (   /* حدث سعر = (تاريخ، مورّد، سعر) */
    select li.itm_code, li.d, li.ven_name_ar, li.itm_pur_price,
           max(li.dis) as dis, sum(li.qnty) as qty, sum(li.bonus) as bonus,
           sum(li.line_total) as tot,
           array_agg(distinct li.branch order by li.branch) as branches,
           row_number() over (partition by li.itm_code
                              order by li.d desc, li.itm_pur_price desc) as rn
      from li
     group by li.itm_code, li.d, li.ven_name_ar, li.itm_pur_price
  ),
  it as (
    select m.itm_code as code, m.itm_name as name, m.exact,
           (select max(g.d) from g where g.itm_code = m.itm_code) as last_d,
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'd', g.d, 'ven', g.ven_name_ar,
                     'price', round(g.itm_pur_price, 2),
                     'dis', round(g.dis, 2),
                     'qty', round(g.qty, 2),
                     'bonus', round(g.bonus, 2),
                     'eff', case when g.qty + g.bonus > 0
                                 then round(g.tot / (g.qty + g.bonus), 2) end,
                     'branches', g.branches) order by g.d desc), '[]'::jsonb)
              from g where g.itm_code = m.itm_code
               and g.rn <= greatest(1, least(p_hist, 12))) as prices
      from m
  )
  select coalesce(jsonb_agg(to_jsonb(x) - 'exact'), '[]'::jsonb) into v_res
    from (select * from it where last_d is not null
           order by exact desc, last_d desc
           limit greatest(1, least(p_limit, 15))) x;

  return v_res;
end
$fn$;

revoke all on function public.search_item_cost(text, integer, integer) from public, anon;
grant execute on function public.search_item_cost(text, integer, integer) to authenticated;

notify pgrst, 'reload schema';
