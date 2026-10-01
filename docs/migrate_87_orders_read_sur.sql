/* ═══════════════════════════════════════════════════════════════════
   الطلبيات تقرا معدل الفائض الجاهز بدل ما تحسبه بنفسها
   ═══════════════════════════════════════════════════════════════════
   بيكمّل 85 و86. منطق الفرع الجديد اللي كان مكتوب جوّه الدالة
   (migrate_84) اتنقل لمكانه الصح — `get_consumption_rates` —
   وبقى بيطلّع عمود `sur_<الفرع>` جاهز. الدالة دي بقت تقراه وخلاص.

   وكمان بقت تقرا من `branch_calc_settings`:
     • `min_stock_surplus` لكل فرع × تصنيف بدل الرقم العام الواحد
     • `active` — الفرع المقفول **مايدّيش فائض** لباقي الفروع
       (ده المفتاح اللي بيلغي/يفعّل مساهمة الفرع في الفائض)

   ⚠️ الشراء (`req_qty`) لسه على `r_` (معدل الشراء). الفائض على `sr_`.
      الفرق بينهم بيتحدد في الإعدادات مش هنا.

   ⚠️ فلتر `sf.med = 1` اتساب زي ما هو **بقصد**: ده بيحدد «أنهي شاشة
      تعرض الصنف» مش «إزاي يتحسب معدله». الـ6 أصناف اللي شركتها
      «ورقيات» ومتعلّمة med=1 بقت تاخد **معدل الورقيات** (من 86)
      وهي لسه بتظهر في شاشة الأدوية. توحيد الشاشات سؤال منفصل.

   اتحقق بعد التطبيق: صفر صف اتغيّر في purchase_orders_flat — إعادة
   الهيكلة طلّعت نفس النتيجة بالحرف (3,731 صف).

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
  v_join   text := '';
  v_arms   text := '';
  v_sel    text;
  v_sql    text;
  v_sum    text;
  v_max    text;
  v_net    text;
  v_mss    text;
  r        record;
  o        record;
  c        record;
begin
  for r in select * from public.branch_letters() loop
    v_base := v_base
      || ', sf.' || quote_ident(r.letter || '_q') || ' q_'  || r.code
      || ', sf.' || quote_ident(r.letter || '_p') || ' p_'  || r.code
      || ', coalesce(cf.' || quote_ident('av_'   || r.code) || ',0) r_'   || r.code
      || ', coalesce(cf.' || quote_ident('sur_'  || r.code) || ',0) sr_'  || r.code
      || ', coalesce(cf.' || quote_ident('base_' || r.code) || ',0) bs_'  || r.code
      || ', coalesce(cf.' || quote_ident('act_'  || r.code) || ',0) act_' || r.code;

    v_join := v_join
      || ' left join public.branch_calc_settings g_' || r.code
      || '   on g_' || r.code || '.branch = ' || quote_literal(r.name)
      || '  and g_' || r.code || '.category = b._cat'
      || '  and g_' || r.code || '.active';

    v_mss := 'coalesce(g_' || r.code || '.min_stock_surplus, (select mss from cfg))';

    v_calc := v_calc
      || ', floor((select req_qty(b.r_' || r.code || ', b.q_' || r.code || ', mn, ratio) from cfg))::int req_' || r.code
      || ', (case when g_' || r.code || '.branch is null then 0'
      || '        when b.q_' || r.code || ' >= ' || v_mss
      || '        and floor(b.q_' || r.code || ' - b.sr_' || r.code || ') > 0'
      || '       then floor(b.q_' || r.code || ' - b.sr_' || r.code || ')::int else 0 end) sur_' || r.code;

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
    || '          sf.u unit, sf.co company, sf.med,'
    || '          public.item_category(sf.co, sf.med) _cat' || v_base || ','
    || '          exists(select 1 from ex_archived_items e where e.itm_code = sf.itm_code) exarch'
    || '     from stock_flat sf'
    || '     left join consumption_flat cf on cf.code = sf.itm_code'
    || '    where sf.itm_code not in (select itm_code from archived_items) and sf.med = 1'
    || ' ), calc as ('
    || '   select b.*' || v_calc || v_latsel
    || '     from base b' || v_join || v_lat
    || ' )' || v_arms;

  return query execute v_sql;
end
$fn$;
