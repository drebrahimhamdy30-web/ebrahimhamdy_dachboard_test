-- ═══════════════════════════════════════════════════════════════════
-- أ-2 · خطوة ٥: تفاصيل معدل الاستهلاك من جدول الفروع
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين** — وبعد migrate_51 و 52)
--
-- `get_consumption_detail` (لوحة «تفاصيل المعدل» في طلبيات الأدوية)
-- كانت كلها بلواحق _m/_s/_b: المعدل الخام، الشهور النشطة، معامل
-- التغطية، تفصيل المصادر، ومبيعات الشهور. كل حسبة مكتوبة ثلاث مرات.
--
-- بقت لفّة على `branch_letters()`. و`branches` في الرد بقى فيه
-- `name` و`sort` كذلك، فالشاشة تبني صفوفها من الرد من غير خريطة محلية.
--
-- التوافق: `branches` و`months` أصلًا مفاتيحهم بأكواد الفروع فمفيش
--   كسر. تفصيل المصادر كان بلواحق الحروف (base_m/act_m)، فبقى فيه
--   كائن `br` بالكود **ومعاه** المفاتيح القديمة بالحرف — عشان شاشة
--   ماتعدّلتش بعد ماتقعش في الفترة بين نشر القاعدة ونشر الكود.
--
-- التحقق على السحابة (صنف 6404 — له كودين بديلين فبيمرّ على مسار
-- المصادر المركّب):
--   · المعمورة 9.31 / 11.2 / 9 / 1.2   — مطابق لما قبل التعديل
--   · سان      18.92 / 24.6 / 9 / 1.3  — مطابق
--   · بشر      3.00 / 3.3 / 2 / 1.1    — مطابق
--   · المصدر الأول base_m/base_s/base_b = 6.56 / 5.11 / 2.00 — مطابق
--   · والسيوف اتضاف بأصفار
--
-- وفحص متقاطع أقوى: `branches.<code>.final` من الدالة دي مقابل
--   `consumption_flat.av_<code>` (اللي get_consumption_rates بتحسبها،
--   ودالة تانية اتكتبت منفصلة) على 60 صنف → **صفر خلاف**.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.get_consumption_detail(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_self  boolean := not exists (select 1 from code_replace where code = p_code);
  f_rate  text := '';
  f_agg   text := '';
  f_fac   text := '';
  o_br    text := '';
  o_srcbr text := '';
  o_srclg text := '';
  o_mon   text := '';
  v_sql   text;
  res     jsonb;
  r       record;
  v_has   boolean;
begin
  for r in select * from public.branch_letters() loop
    v_has := exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name='monthly_sales'
                        and column_name = r.code);

    if v_has then
      f_rate := f_rate
        || ', case when count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) > 0'
        || '       then sum(ms.' || quote_ident(r.code) || ')::numeric'
        || '          / count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0)'
        || '       else 0 end r_' || r.code
        || ', count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) act_' || r.code;
      o_mon := o_mon || ', ' || quote_literal(r.code) || ', ms.' || quote_ident(r.code);
    else
      f_rate := f_rate || ', 0::numeric r_' || r.code || ', 0::bigint act_' || r.code;
      o_mon  := o_mon  || ', ' || quote_literal(r.code) || ', 0';
    end if;

    f_agg := f_agg
      || ', coalesce(sum(r_' || r.code || ' * qty), 0) pre_' || r.code
      || ', coalesce(max(act_' || r.code || '), 0) act_' || r.code;

    f_fac := f_fac
      || ', coalesce((select save_factor from demand_tiers t'
      || '   where a.pre_' || r.code || ' >= t.rate_min and a.act_' || r.code || ' >= t.active_min'
      || '   order by t.rate_min desc limit 1), 1) f_' || r.code;

    o_br := o_br
      || ', ' || quote_literal(r.code) || ', jsonb_build_object('
      || '''name'', '   || quote_literal(r.name) || ', '
      || '''sort'', '   || coalesce(r.sort_order, 999)::text || ', '
      || '''pre'', round(f.pre_'  || r.code || ', 2), '
      || '''active'', f.act_'     || r.code || ', '
      || '''exc'', f.exc, '
      || '''factor'', f.f_'       || r.code || ', '
      || '''final'', round(f.pre_' || r.code || ' * f.exc * f.f_' || r.code || ', 1))';

    o_srcbr := o_srcbr
      || ', ' || quote_literal(r.code) || ', jsonb_build_object('
      || '''base'', round(r_' || r.code || ', 2), ''act'', act_' || r.code || ')';

    o_srclg := o_srclg
      || ', ' || quote_literal('base_' || r.letter) || ', round(r_' || r.code || ', 2)'
      || ', ' || quote_literal('act_'  || r.letter) || ', act_' || r.code;
  end loop;

  v_sql :=
       'with srcs as ('
    || '  select $1 as src, 1::numeric qty, true is_self where $2'
    || '  union all'
    || '  select cr.code, cr.qty, false from code_replace cr where cr.replace = $1'
    || '), srcrate as ('
    || '  select s.src, s.qty, s.is_self, coalesce(ce.qty,1) exc' || f_rate
    || '    from srcs s'
    || '    left join monthly_sales ms on ms.itm_code = s.src'
    || '    left join consumption_exceptional ce on ce.itm_code = s.src'
    || '   group by s.src, s.qty, s.is_self, ce.qty'
    || '), agg as ('
    || '  select coalesce(max(exc),1) exc' || f_agg || ' from srcrate'
    || '), fac as ('
    || '  select a.*' || f_fac || ' from agg a'
    || ')'
    || ' select jsonb_build_object('
    || '   ''code'', $1,'
    || '   ''itm_name'', (select max(ms.itm_name) from monthly_sales ms'
    || '                   where ms.itm_code in (select src from srcs)),'
    || '   ''is_source'', not $2,'
    || '   ''redirected_to'', (select jsonb_agg(jsonb_build_object(''replace'', cr.replace, ''qty'', cr.qty))'
    || '                        from code_replace cr where cr.code = $1),'
    || '   ''branches'', jsonb_build_object(' || ltrim(o_br, ', ') || '),'
    || '   ''sources'', (select jsonb_agg(jsonb_build_object('
    || '        ''code'', src, ''qty'', qty, ''is_self'', is_self, ''exc'', exc,'
    || '        ''br'', jsonb_build_object(' || ltrim(o_srcbr, ', ') || ')'
    || o_srclg
    || '      ) order by is_self desc, src) from srcrate),'
    || '   ''months'', (select jsonb_agg(jsonb_build_object('
    || '        ''src'', ms.itm_code, ''month'', ms.month'
    || o_mon
    || '      ) order by ms.itm_code, ms.month desc)'
    || '      from monthly_sales ms where ms.itm_code in (select src from srcs))'
    || ' ) from fac f';

  execute v_sql into res using p_code, v_self;
  return res;
end $fn$;

grant execute on function public.get_consumption_detail(text) to public, anon, authenticated;

notify pgrst, 'reload schema';
