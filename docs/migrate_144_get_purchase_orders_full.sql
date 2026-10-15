/* ═══════════════════════════════════════════════════════════════════
   get_purchase_orders — النسخة الكاملة (تصفير انحراف السحابة/الذاتي)
   ═══════════════════════════════════════════════════════════════════
   الدالة دي اتعدّلت على السحابة **بالإيد مرتين** من غير ملف ترحيل:
     • نقطة الطلب لكل فرع×تصنيف (migrate_100) —
       `coalesce(g_<code>.min_immediate, mn)` و`…reorder_ratio, ratio`
     • أعمدة قرب الصلاحية (migrate_139) — `exp_branch/exp_qty/exp_date`
       وخصم `ex.qty` من `net_required`

   فالسيرفر الذاتي كان بياخد الأعمدة ومايحسبهاش: الجدول فيه الخانات،
   والدالة اللي بتملاها نسخة قديمة. وعمود فاضي مش رسالة خطأ — فالشاشة
   كانت هتفضل تقول «مفيش مرشّح» للأبد من غير ما حد يعرف ليه.

   ⚠️ الدرس: `create or replace function` على القاعدة مباشرة من غير
      ملف = انحراف مستخبي. الدوال الديناميكية دي بتتبني كاملة في كل
      مرة، فالملف ده نسخة كاملة — مش فرق.

   المتن هنا هو نسخة السحابة بالحرف + تعليقات شرح زيادة، فالـmd5
   مختلف عن 6249404c61e0dfefcdaf366be7f43542 بقصد. الفحص اللي اتعمل
   سلوكي: اتطبّق على السحابة وطلع **نفس** الناتج بالضبط
   (4,420 سطر · 63 مرشّح · 102 قطعة · ~9,760 جنيه).

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
      || ', coalesce(cf.' || quote_ident('act_'  || r.code) || ',0) act_' || r.code
      || ', cf.' || quote_ident('bills_' || r.code) || ' bl_' || r.code;

    /* إعدادات الفرع لتصنيف الصنف — مصدر «أقل رصيد لاعتبار فائض»
       ومفتاح «داخل الحسابات». صف ناقص/مقفول = الفرع مايدّيش فائض. */
    v_join := v_join
      || ' left join public.branch_calc_settings g_' || r.code
      || '   on g_' || r.code || '.branch = ' || quote_literal(r.name)
      || '  and g_' || r.code || '.category = b._cat'
      || '  and g_' || r.code || '.active';

    v_mss := 'coalesce(g_' || r.code || '.min_stock_surplus, (select mss from cfg))';

    /* الفائض بمعدل الفائض (sr_) مش معدل الشراء (r_) — الفرق بينهم
       بيتحدد في branch_calc_settings.surplus_mode وبيتحسب مرة واحدة
       في get_consumption_rates. هنا بنقراه جاهز.
       ونقطة الطلب: الفاضي في إعدادات الفرع بياخد العام من cfg. */
    v_calc := v_calc
      || ', floor((select req_qty(b.r_' || r.code || ', b.q_' || r.code || ', coalesce(g_' || r.code || '.min_immediate, mn)' || ', coalesce(g_' || r.code || '.reorder_ratio, ratio)) from cfg))::int req_' || r.code
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

    /* الخصم بـ**الأكبر** من فائض الفروع أو الكمية قريبة الصلاحية —
       مش مجموعهم: التحويلة بتيجي من فرع واحد.
       و`::int` مقصود — net_required عمود integer و`ex.qty` numeric،
       وبدونه الدالة بتقع وقت التشغيل مش وقت الإنشاء. */
    if v_max = '' then
      v_net := 'greatest(0, c.req_' || r.code || ' - coalesce(ex.qty,0)::int)';
    else
      v_net := 'greatest(0, c.req_' || r.code || ' - greatest(' || v_max || ', coalesce(ex.qty,0)::int))';
    end if;

    v_sel := '';
    for c in
      select column_name, udt_name from information_schema.columns
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
        when c.column_name = 'sale_bills'     then 'c.bl_'  || r.code
        when c.column_name = 'net_required'   then v_net
        when c.column_name = 'send_qty'       then 'coalesce(sq.qty, ' || v_net || ')::int'
        when c.column_name = 'surplus_other'  then '(' || v_sum || ')'
        when c.column_name like 'surplus\_%'  then 'coalesce(c.sur_' || substr(c.column_name, 9) || ', 0)'
        when c.column_name = 'best_store'     then 'coalesce(ov.store, c.bstore_'      || r.code || ')'
        when c.column_name = 'best_price'     then 'coalesce(ov.price, c.bprice_'      || r.code || ')'
        when c.column_name = 'best_disc'      then 'coalesce(ov.disc, c.bdisc_'        || r.code || ')'
        when c.column_name = 'best_item_name' then 'coalesce(ov.item_name, c.bname_'   || r.code || ')'
        when c.column_name = 'ex_archived'    then 'c.exarch'
        when c.column_name = 'exp_branch'     then 'ex.branch'
        when c.column_name = 'exp_qty'        then 'ex.qty::int'
        when c.column_name = 'exp_date'       then 'ex.exp_date'
        when c.column_name = 'refreshed_at'   then 'now()'
        /* ⚠️ `null` من غير نوع بيتقرا text، والدالة بترجّع
           `setof purchase_orders_flat` فأي عمود مش text بيوقّعها وقت
           التشغيل: «Returned type text does not match expected type
           boolean in column 32». حصل أول ما اتضاف عمود excluded.
           الكاست بيخلّي أي عمود جديد يعدّي من غير ما يلمس الدالة. */
        else 'null::' || c.udt_name
      end;
    end loop;
    v_sel := ltrim(v_sel, ', ');

    v_arms := v_arms
      || case when v_arms = '' then '' else ' union all ' end
      || ' select ' || v_sel
      || '   from calc c'
      || '   left join order_store_override ov'
      || '     on ov.branch = ' || quote_literal(r.name) || ' and ov.itm_code = c.itm_code'
      || '   left join lateral public.expiry_source_for(' || quote_literal(r.name) || ', c.itm_code) ex on true'
      || '   left join order_send_qty sq'
      || '     on sq.branch = ' || quote_literal(r.name) || ' and sq.itm_code = c.itm_code'
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

revoke all on function public.get_purchase_orders() from public, anon;
grant execute on function public.get_purchase_orders() to authenticated, service_role;
