/* ═══════════════════════════════════════════════════════════════════
   الفرع الجديد: الفائض يتحسب بمعدل الفرع المصدر مش بمعدله المشتق
   ═══════════════════════════════════════════════════════════════════
   المشكلة (اتقاست 2026-10-01):
     الفائض = الرصيد − المعدل. الفرع الجديد (السيوف) معدله مشتق ونسبة
     من معدل المصدر (شرائح 20–25% للأصناف السريعة)، فرصيده بيتقرا فائض
     ضخم: **3,556 وحدة على 1,071 صنف**، منها 94% على أصناف عمرها ما
     اتباعت هناك. والفائض ده بيخصم من شراء الفروع التانية:
     209 صنف اتقطعوا · 360 وحدة · 44,578 جنيه · 126 صنف اتلغى طلبهم.

   ليه القاعدة العامة مش الحل:
     «الصنف اللي مابيتباعش مايحتسبش فائضه» تبان منطقية، بس الفروع
     الناضجة ربع فائضها بالظبط من النوع ده — صنف وقف بيعه ولسه في
     المخزن، وده **فائض حقيقي ومرغوب تحويله**. القاعدة العامة كانت
     هتضيّع ~950 وحدة منه. فالمعاملة الخاصة لازم تكون للفرع الجديد بس.

   القاعدة (قرار المالك):
     طول ما خاصية المعدل المشتق مفعّلة للفرع، فائضه يتحسب بـ**معدل
     الفرع المصدر الكامل** مع رصيده الحالي — مش بمعدله المشتق.
     المنطق: الشريحة المنخفضة متحفّظة في **الشراء** (مانشتريش لفرع لسه
     مابيبيعش). نفس التحفّظ في **الفائض** يتطلب معدل **أعلى**، وإلا
     الرصيد كله يتقرا فائض. فالاتجاه المتحفّظ في الحالتين.

   الشرط **نفس شرط المعدل المشتق بالحرف** (act_target = 0 و av_source > 0)
   عشان الاتنين يشتغلوا ويتوقفوا مع بعض: أول ما الصنف يتباع في الفرع
   الجديد، يرجع معدله الحقيقي في الشراء **وفي الفائض** في نفس اللحظة.
   مافيش خطوة يدوية ومافيش إعداد جديد — المفتاح هو `new_branch_rate.active`
   الموجود أصلًا في «إعدادات المشتريات».

   ⚠️ الشراء مالوش دعوة: `req_qty` بيفضل على المعدل المشتق زي ما هو.
      التعديل في تعبير `sur_` بس.

   الأثر المقاس:
     فائض السيوف: 3,556 → 1,657 وحدة (447 صنف بدل 1,071)
     بيرجع لشراء الفروع التانية: 260 وحدة · 28,790 جنيه · 77 صنف
     الـ1,657 الباقية فائض حقيقي (رصيد أعلى من معدل المصدر نفسه).

   مابيتغيّرش: منطق الخصم (أكبر فائض عند فرع واحد) ولا عمود العرض
   (مجموع الفروع) — قرار المالك يسيبهم زي ما هم.

   بعد الترحيل: select refresh_purchase_orders();

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_purchase_orders()
returns setof public.purchase_orders_flat
language plpgsql
as $fn$
declare
  v_base   text := '';
  v_calc   text := '';
  v_lat    text := '';
  v_latsel text := '';
  v_arms   text := '';
  v_sel    text;
  v_sql    text;
  v_sum    text;
  v_max    text;
  v_net    text;
  v_src    text;
  v_rate   text;
  r        record;
  o        record;
  c        record;
begin
  for r in select * from public.branch_letters() loop
    v_base := v_base
      || ', sf.' || quote_ident(r.letter || '_q') || ' q_'  || r.code
      || ', sf.' || quote_ident(r.letter || '_p') || ' p_'  || r.code
      || ', coalesce(cf.' || quote_ident('av_'   || r.code) || ',0) r_'   || r.code
      || ', coalesce(cf.' || quote_ident('base_' || r.code) || ',0) bs_'  || r.code
      || ', coalesce(cf.' || quote_ident('act_'  || r.code) || ',0) act_' || r.code;

    /* الفرع الجديد: لو له مصدر مفعّل، فائضه يتحسب بمعدل المصدر الكامل
       تحت نفس شرط المعدل المشتق في get_consumption_rates. */
    v_src := null;
    select bs.code into v_src
      from public.new_branch_rate nbr
      join public.branch_letters() bt on bt.name = nbr.target_branch
      join public.branch_letters() bs on bs.name = nbr.source_branch
     where nbr.active and bt.code = r.code and bs.code <> r.code
     limit 1;

    if v_src is null then
      v_rate := 'b.r_' || r.code;
    else
      v_rate := '(case when coalesce(b.act_' || r.code || ',0) = 0'
             || '       and coalesce(b.r_'   || v_src  || ',0) > 0'
             || '      then b.r_' || v_src || ' else b.r_' || r.code || ' end)';
    end if;

    v_calc := v_calc
      || ', floor((select req_qty(b.r_' || r.code || ', b.q_' || r.code || ', mn, ratio) from cfg))::int req_' || r.code
      || ', (case when b.q_' || r.code || ' >= (select mss from cfg)'
      || '        and floor(b.q_' || r.code || ' - ' || v_rate || ') > 0'
      || '       then floor(b.q_' || r.code || ' - ' || v_rate || ')::int else 0 end) sur_' || r.code;

    v_lat := v_lat
      || ' left join lateral best_store_for(' || quote_literal(r.name) || ', b.itm_code) bw_' || r.code || ' on true';

    v_latsel := v_latsel
      || ', bw_' || r.code || '.store bstore_'         || r.code
      || ', bw_' || r.code || '.price bprice_'         || r.code
      || ', bw_' || r.code || '.discount_perc bdisc_'  || r.code
      || ', bw_' || r.code || '.item_name bname_'      || r.code;
  end loop;

  for r in select * from public.branch_letters() loop
    v_sum := ''; v_max := '';
    for o in select * from public.branch_letters() where code <> r.code loop
      v_sum := v_sum || case when v_sum = '' then '' else ' + ' end || 'c.sur_' || o.code;
      v_max := v_max || case when v_max = '' then '' else ', ' end || 'c.sur_' || o.code;
    end loop;
    if v_sum = '' then v_sum := '0'; end if;

    if v_max = '' then
      v_net := 'c.req_' || r.code;
    else
      v_net := 'greatest(0, c.req_' || r.code || ' - greatest(' || v_max || '))';
    end if;

    v_sel := '';
    for c in
      select column_name from information_schema.columns
       where table_schema = 'public' and table_name = 'purchase_orders_flat'
       order by ordinal_position
    loop
      v_sel := v_sel || ', ' || case
        when c.column_name = 'id'             then 'null::bigint'
        when c.column_name = 'branch'         then quote_literal(r.name)
        when c.column_name = 'itm_code'       then 'c.itm_code'
        when c.column_name = 'itm_name'       then 'c.itm_name'
        when c.column_name = 'unit'           then 'c.unit'
        when c.column_name = 'company'        then 'c.company'
        when c.column_name = 'med'            then 'c.med'
        when c.column_name = 'price'          then 'c.p_'   || r.code
        when c.column_name = 'stock'          then 'c.q_'   || r.code
        when c.column_name = 'rate'           then 'c.r_'   || r.code
        when c.column_name = 'base_rate'      then 'c.bs_'  || r.code
        when c.column_name = 'required'       then 'c.req_' || r.code
        when c.column_name = 'active_months'  then 'c.act_' || r.code
        when c.column_name = 'net_required'   then v_net
        when c.column_name = 'surplus_other'  then '(' || v_sum || ')'
        when c.column_name like 'surplus\_%'  then 'coalesce(c.sur_' || substr(c.column_name, 9) || ', 0)'
        when c.column_name = 'best_store'     then 'coalesce(ov.store, c.bstore_'      || r.code || ')'
        when c.column_name = 'best_price'     then 'coalesce(ov.price, c.bprice_'      || r.code || ')'
        when c.column_name = 'best_disc'      then 'coalesce(ov.disc, c.bdisc_'        || r.code || ')'
        when c.column_name = 'best_item_name' then 'coalesce(ov.item_name, c.bname_'   || r.code || ')'
        when c.column_name = 'ex_archived'    then 'c.exarch'
        when c.column_name = 'refreshed_at'   then 'now()'
        else 'null'
      end;
    end loop;
    v_sel := ltrim(v_sel, ', ');

    v_arms := v_arms
      || case when v_arms = '' then '' else ' union all ' end
      || ' select ' || v_sel
      || '   from calc c'
      || '   left join order_store_override ov'
      || '     on ov.branch = ' || quote_literal(r.name) || ' and ov.itm_code = c.itm_code'
      || '  where c.req_' || r.code || ' > 0';
  end loop;

  v_sql :=
       'with cfg as (select min_immediate mn, reorder_ratio ratio, min_stock_surplus mss'
    || '               from purchase_settings where id = 1),'
    || ' base as ('
    || '   select sf.itm_code, coalesce(nullif(sf.n,''''), cf.itm_name) itm_name,'
    || '          sf.u unit, sf.co company, sf.med' || v_base || ','
    || '          exists(select 1 from ex_archived_items e where e.itm_code = sf.itm_code) exarch'
    || '     from stock_flat sf'
    || '     left join consumption_flat cf on cf.code = sf.itm_code'
    || '    where sf.itm_code not in (select itm_code from archived_items) and sf.med = 1'
    || ' ), calc as ('
    || '   select b.*' || v_calc || v_latsel
    || '     from base b' || v_lat
    || ' )' || v_arms;

  return query execute v_sql;
end
$fn$;
