/* ═══════════════════════════════════════════════════════════════════
   مصدر واحد للمعدل والفائض — get_consumption_rates
   ═══════════════════════════════════════════════════════════════════
   بيكمّل migrate_85. الدالة بقت تقرا كل قراراتها من جدولي الإعدادات:
     • `category_rate_tiers`  — معامل الشريحة لكل تصنيف (وفرع اختياريًا)
     • `branch_calc_settings` — مصدر المعدل ونمط الفائض لكل فرع × تصنيف

   بتطلّع عمودين لكل فرع:
     av_<الفرع>   = معدل **الشراء**  (الشريحة المشتقة للفرع الجديد)
     sur_<الفرع>  = معدل **الفائض**  (معدل المصدر الكامل لو الإعداد كده)
   الاتنين بيتحسبوا هنا مرة واحدة، وكل السيستم يقرا منهم.

   ⚠️ تغييرات مقصودة عن السلوك القديم:
   1. المعامل بقى **حسب تصنيف الصنف**:
        أدوية  → نفس شرائح demand_tiers بالحرف (اتنقلت كما هي)
        كوزمو  → معدل ≥ 1 · شهور ≥ 2 · ×1.2   (كانت في المتصفح ومش محفوظة)
        ورقيات → معدل ≥ 1 · شهور ≥ 2 · ×0.75  (كانت سويتش في الشاشة)
      يعني معدل أصناف الكوزمو والورقيات في consumption_flat هيتغيّر —
      ده المقصود: التصنيف بقى له قاعدته بدل ما ياخد قاعدة الأدوية.
   2. الفرع الجديد: المصدر بقى من `branch_calc_settings` لكل تصنيف
      لوحده بدل `new_branch_rate` العام.
   3. شريحة الفرع المحدّد بتغلب على شريحة «كل الفروع» لنفس التصنيف.

   ⚠️ طبقات الاستعلام بقت أربعة وكل واحدة ليها دور:
      raw     → المعدل من مبيعات الفرع نفسه × معامل تصنيفه
      drv     → بدل المعدل بالمشتق لو الإعداد `derived`  → av_*
      final   → يحسب sur_* من av_* النهائي + إعداد الفائض
      وأي تعديل مستقبلي لازم يحافظ على أسماء الأعمدة المساعدة
      (`_cat` · `_rs_*` · `_sb_*` · `_sm_*`) لأن الطبقات بتشاور عليها.

   بعد الترحيل:
     select refresh_consumption_rates();
     select refresh_purchase_orders();

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_consumption_rates()
returns setof public.consumption_flat
language plpgsql
as $fn$
declare
  f_base  text := '';
  f_rate  text := '';
  f_pass  text := '';
  f_agg   text := '';
  v_sel   text := '';
  v_drv   text := '';
  v_fin   text := '';
  v_join  text := '';
  v_extra text := '';
  v_tcode text;
  v_sd    text;   -- معدل المصدر في طبقة drv   (من الـjoin مباشرة)
  v_sf    text;   -- معدل المصدر في طبقة final (من أعمدة drv)
  v_tier  text;
  v_sql   text;
  r       record;
  o       record;
  c       record;
begin
  /* ── المبيعات الخام لكل فرع ─────────────────────────────────── */
  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      f_base := f_base
        || ', sum(ms.' || quote_ident(r.code) || ') sum_' || r.code
        || ', count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) act_' || r.code;
    else
      f_base := f_base
        || ', 0::numeric sum_' || r.code
        || ', 0::bigint  act_' || r.code;
    end if;

    f_rate := f_rate
      || ', case when b.act_' || r.code || ' > 0'
      || '       then b.sum_' || r.code || '::numeric / b.act_' || r.code
      || '       else 0 end r_' || r.code
      || ', coalesce(b.act_' || r.code || ', 0) act_' || r.code;

    f_pass := f_pass || ', br.r_' || r.code || ', br.act_' || r.code;

    f_agg  := f_agg
      || ', sum(r_' || r.code || ' * qmul) pre_' || r.code
      || ', max(act_' || r.code || ') act_' || r.code;
  end loop;

  /* ── طبقة raw: المعدل من مبيعات الفرع × معامل تصنيف الصنف ──── */
  for c in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'consumption_flat'
     order by ordinal_position
  loop
    v_sel := v_sel || case
      when c.column_name = 'code'     then ', a.tcode'
      when c.column_name = 'itm_name' then
        ', coalesce(a.name_primary, (select nullif(s.n,'''') from stock_flat s where s.itm_code = a.tcode), a.name_any)'
      when c.column_name = 'refreshed_at' then ', now()'
      when c.column_name like 'av\_%' then
        /* معامل الشريحة: من تصنيف الصنف، وشريحة الفرع تغلب على العامة */
        ', round(a.pre_' || substr(c.column_name, 4) || ' * a.exc * coalesce((select t.multiply'
        || ' from public.category_rate_tiers t'
        || ' where t.category = a._cat'
        || '   and (t.branch is null or t.branch = ' || quote_literal(coalesce(
             (select bl.name from public.branch_letters() bl where bl.code = substr(c.column_name, 4)),
             '''')) || ')'
        || '   and a.pre_' || substr(c.column_name, 4) || ' >= t.rate_min'
        || '   and a.act_' || substr(c.column_name, 4) || ' >= t.active_min'
        || ' order by (t.branch is not null) desc, t.rate_min desc limit 1), 1), 1)'
      when c.column_name like 'base\_%' then
        ', round(a.pre_' || substr(c.column_name, 6) || ' * a.exc, 1)'
      when c.column_name like 'act\_%' then
        ', a.act_' || substr(c.column_name, 5) || '::int'
      when c.column_name like 'sur\_%' then ', null::numeric'   -- بيتحسب في final
      else ', null'
    end || ' ' || quote_ident(c.column_name);
  end loop;

  /* ── طبقتي drv و final ──────────────────────────────────────── */
  for r in select * from public.branch_letters() loop
    /* إعدادات الفرع لتصنيف الصنف — join مرة واحدة بدل subquery لكل صف */
    v_join := v_join
      || ' left join public.branch_calc_settings s_' || r.code
      || '   on s_' || r.code || '.branch = ' || quote_literal(r.name)
      || '  and s_' || r.code || '.category = x._cat'
      || '  and s_' || r.code || '.active';

    v_extra := v_extra
      || ', s_' || r.code || '.source_branch _sb_' || r.code
      || ', s_' || r.code || '.surplus_mode  _sm_' || r.code;
  end loop;

  for c in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'consumption_flat'
     order by ordinal_position
  loop
    v_tcode := case when c.column_name like 'av\_%'  then substr(c.column_name, 4)
                    when c.column_name like 'sur\_%' then substr(c.column_name, 5) end;

    /* معدل الفرع المصدر = عمود الفرع اللي الإعداد مسمّيه */
    v_sd := null; v_sf := null;
    if v_tcode is not null then
      /* في drv الإعداد جاي من الـjoin؛ وفي final من أعمدة drv */
      v_sd := 'case s_' || v_tcode || '.source_branch';
      v_sf := 'case d._sb_' || v_tcode;
      for o in select * from public.branch_letters() where code <> v_tcode loop
        v_sd := v_sd || ' when ' || quote_literal(o.name) || ' then x.av_' || o.code;
        v_sf := v_sf || ' when ' || quote_literal(o.name) || ' then d.av_' || o.code;
      end loop;
      v_sd := v_sd || ' else null end';
      v_sf := v_sf || ' else null end';
    end if;

    /* ── drv: av_* النهائي ── */
    if c.column_name like 'av\_%' then
      v_tier := 'coalesce((select t.percent / 100 from public.new_branch_rate_tiers t'
             || ' where (' || v_sd || ') >= t.rate_min order by t.rate_min desc limit 1), 0)';
      v_drv := v_drv
        || ', case when s_' || v_tcode || '.rate_source = ''derived'''
        || '        and coalesce(x.act_' || v_tcode || ', 0) = 0'
        || '        and coalesce(' || v_sd || ', 0) > 0'
        || '       then round(coalesce(' || v_sd || ', 0) * ' || v_tier || ', 1)'
        || '       else x.' || quote_ident(c.column_name) || ' end ' || quote_ident(c.column_name);
    else
      v_drv := v_drv || ', x.' || quote_ident(c.column_name);
    end if;

    /* ── final: sur_* ── */
    if c.column_name like 'sur\_%' then
      v_fin := v_fin
        || ', case when d._sm_' || v_tcode || ' = ''source_full'''
        || '        and coalesce(d.act_' || v_tcode || ', 0) = 0'
        || '        and coalesce(' || v_sf || ', 0) > 0'
        || '       then ' || v_sf
        || '       else d.av_' || v_tcode || ' end ' || quote_ident(c.column_name);
    else
      v_fin := v_fin || ', d.' || quote_ident(c.column_name);
    end if;
  end loop;

  v_sel := ltrim(v_sel, ', ');
  v_drv := ltrim(v_drv, ', ');
  v_fin := ltrim(v_fin, ', ');

  v_sql :=
       'with base as ('
    || '  select ms.itm_code, max(ms.itm_name) itm_name' || f_base
    || '    from monthly_sales ms group by ms.itm_code'
    || '), base_rate as ('
    || '  select b.itm_code, b.itm_name' || f_rate || ', coalesce(ce.qty,1) exc'
    || '    from base b left join consumption_exceptional ce on ce.itm_code = b.itm_code'
    || '), expanded as ('
    || '  select br.itm_code tcode, br.itm_name' || f_pass || ', br.exc, 1::numeric qmul, true is_primary'
    || '    from base_rate br'
    || '   where not exists (select 1 from code_replace cr where cr.code = br.itm_code)'
    || '  union all'
    || '  select cr.replace, br.itm_name' || f_pass || ', br.exc, cr.qty, false is_primary'
    || '    from base_rate br join code_replace cr on cr.code = br.itm_code'
    || '), agg as ('
    || '  select tcode,'
    || '         max(itm_name) filter (where is_primary) name_primary,'
    || '         max(itm_name) name_any' || f_agg || ', max(exc) exc'
    || '    from expanded group by tcode'
    /* تصنيف الصنف مرة واحدة — الطبقات اللي بعدها كلها بتشاور عليه */
    || '), catted as ('
    || '  select a.*, coalesce((select public.item_category(s.co, s.med) from stock_flat s'
    || '                         where s.itm_code = a.tcode limit 1), ''cos'') _cat'
    || '    from agg a'
    || '), raw as (select ' || v_sel || ', a._cat from catted a'
    || '), drv as (select ' || v_drv || ', x._cat' || v_extra
    || '             from raw x' || v_join
    || '), final as (select ' || v_fin || ' from drv d'
    || ') select * from final';

  return query execute v_sql;
end
$fn$;
