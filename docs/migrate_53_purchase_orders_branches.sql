-- ═══════════════════════════════════════════════════════════════════
-- أ-2 · خطوة ٣: الطلبيات من جدول الفروع
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين** — وبعد migrate_51 و 52)
--
-- `get_purchase_orders` أصعب واحدة في السلسلة:
--   • RETURNS TABLE بأعمدة ثابتة (surplus_mamora/san/bishr)
--   • UNION ALL بذراع لكل فرع، كل ذراع مكتوبة بالكامل
--   • متغيّرات لكل فرع: mq/sq/bq · rm/rs/rb · req_m/req_s/req_b …
--   • أسماء فروع عربية مكتوبة جوّه best_store_for و order_store_override
--   • ومنطق «كل الفروع ما عدا أنا» متحسّب بالإيد في كل ذراع
--
-- الحل: نفس نمط خطوة ٢ — `returns setof public.purchase_orders_flat`
--   والإخراج بيتبني بترتيب أعمدة الجدول نفسه، وذراع UNION لكل فرع
--   بتتولّد. العمود اللي `sync_branch_sales_columns()` بتضيفه بيدخل
--   الحسبة لوحده.
--
-- ⚠️ حالة الفرع الواحد: `greatest()` من غير معاملات **خطأ** في
--   بوستجرس. لو مفيش فروع تانية: net_required = required
--   و surplus_other = 0. مالهاش لازمة دلوقتي بس هي أول حاجة تقع لو
--   حد عطّل فروع وساب واحد.
--
-- ⚠️ الأداء: فيه `lateral best_store_for(...)` لكل فرع، فالفرع الرابع
--   بيزوّد الشغل ~الثلث.
--
-- ⚠️ السيوف مالهاش استهلاك (av_seyouf = 0) فـrequired صفر وذراعها
--   مش هتنتج صفوف (`where req > 0`). ده **الصح** دلوقتي وهيشتغل
--   لوحده أول ما الفرع يبيع.
--   الضمان: صفوف الفروع التلاتة لازم تطلع **مطابقة بالحرف** (md5).
-- ═══════════════════════════════════════════════════════════════════

drop function if exists public.get_purchase_orders();

create function public.get_purchase_orders()
returns setof public.purchase_orders_flat
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_base   text := '';   -- أعمدة كل فرع في base
  v_calc   text := '';   -- الاحتياج والفائض لكل فرع
  v_lat    text := '';   -- join lateral لأفضل مخزن لكل فرع
  v_latsel text := '';   -- أعمدة الـlateral جوّه calc
  v_arms   text := '';   -- أذرع UNION ALL
  v_sel    text;
  v_sql    text;
  v_sum    text;
  v_max    text;
  v_net    text;
  r        record;
  o        record;
  c        record;
begin
  -- ── أعمدة كل فرع ────────────────────────────────────────────────
  for r in select * from public.branch_letters() loop
    v_base := v_base
      || ', sf.' || quote_ident(r.letter || '_q') || ' q_'  || r.code
      || ', sf.' || quote_ident(r.letter || '_p') || ' p_'  || r.code
      || ', coalesce(cf.' || quote_ident('av_'   || r.code) || ',0) r_'   || r.code
      || ', coalesce(cf.' || quote_ident('base_' || r.code) || ',0) bs_'  || r.code
      || ', coalesce(cf.' || quote_ident('act_'  || r.code) || ',0) act_' || r.code;

    v_calc := v_calc
      || ', floor((select req_qty(b.r_' || r.code || ', b.q_' || r.code || ', mn, ratio) from cfg))::int req_' || r.code
      || ', (case when b.q_' || r.code || ' >= (select mss from cfg)'
      || '        and floor(b.q_' || r.code || ' - b.r_' || r.code || ') > 0'
      || '       then floor(b.q_' || r.code || ' - b.r_' || r.code || ')::int else 0 end) sur_' || r.code;

    v_lat := v_lat
      || ' left join lateral best_store_for(' || quote_literal(r.name) || ', b.itm_code) bw_' || r.code || ' on true';

    v_latsel := v_latsel
      || ', bw_' || r.code || '.store bstore_'         || r.code
      || ', bw_' || r.code || '.price bprice_'         || r.code
      || ', bw_' || r.code || '.discount_perc bdisc_'  || r.code
      || ', bw_' || r.code || '.item_name bname_'      || r.code;
  end loop;

  -- ── ذراع لكل فرع ────────────────────────────────────────────────
  for r in select * from public.branch_letters() loop
    v_sum := ''; v_max := '';
    for o in select * from public.branch_letters() where code <> r.code loop
      v_sum := v_sum || case when v_sum = '' then '' else ' + ' end || 'c.sur_' || o.code;
      v_max := v_max || case when v_max = '' then '' else ', ' end || 'c.sur_' || o.code;
    end loop;
    if v_sum = '' then v_sum := '0'; end if;

    if v_max = '' then
      v_net := 'c.req_' || r.code;                       -- مفيش فرع تاني يغطّي
    else
      v_net := 'greatest(0, c.req_' || r.code || ' - greatest(' || v_max || '))';
    end if;

    -- الإخراج بترتيب أعمدة purchase_orders_flat
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
        else 'null'    -- عمود مش معروف: فاضي بدل ما الدالة تقع
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
end $fn$;

-- الصلاحيات: الدالة كانت على الافتراضي (PUBLIC) — سايبينها زي ما هي.

-- ── إعادة البناء: قايمة أعمدة صريحة من الجدول (من غير id) ────────
create or replace function public.refresh_purchase_orders()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  n     int;
  v_cols text;
begin
  if coalesce(current_setting('request.jwt.claims', true),'') <> '' then
    perform public.require_app_role(array['admin','manager','pharmacist']);
  end if;

  -- id عمود bigserial (nextval NOT NULL)، فبنستثنيه من القايمة
  -- ونسيب القاعدة تولّده. القايمة بتتبني من الجدول نفسه عشان
  -- ماتفضلش ناقصة عمود الفرع الجديد.
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'purchase_orders_flat'
     and column_name <> 'id';

  truncate purchase_orders_flat;
  execute 'insert into purchase_orders_flat (' || v_cols || ')'
       || ' select ' || v_cols || ' from public.get_purchase_orders()';
  get diagnostics n = row_count;
  return n;
end $fn$;

grant execute on function public.refresh_purchase_orders() to public, anon, authenticated;

notify pgrst, 'reload schema';
