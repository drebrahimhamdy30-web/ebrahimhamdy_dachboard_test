/* ═══════════════════════════════════════════════════════════════════
   الصنف الشاذ = اتباع على فاتورة واحدة — المعدل ينزل لـ1
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   المعدل = إجمالي المبيعات ÷ **الشهور النشطة**. فالصنف اللي اتباع في
   شهر واحد بس بياخد كل الكمية كمعدل شهري دائم:
     ساكسيندا — المعمورة: 9 أقلام في يناير وصفر لتسع شهور → معدل 9
     → مطلوب 8 أقلام بـ13,396 جنيه لفرع مابعش ولا قلم من 9 شهور.

   و«نشط شهر واحد» لوحده **مؤشر ضعيف**: بيصطاد 1,056 سطر فيهم أصناف
   ماشية فعلًا. مثال: سيميلاك جولد 2 — المعمورة باعت 11 علبة على
   **10 فواتير** مختلفة في شهر، يعني 10 زباين — ده صنف شغّال وشهره
   النشط واحد لأنه بدأ في سبتمبر بس.

   ── القاعدة (قرار المالك) ────────────────────────────────────────
   الحكم من **الفواتير** مش من المعدل:
     • الكمية اتباعت على **فاتورة واحدة**  →  شاذ  →  المعدل ينزل لـ1
     • اتباعت على **أكتر من فاتورة**       →  مش شاذ، صنف شغّال
       (يا إما جديد في السوق ولسه نازل، يا إما كان ناقص ونزل —
        وفي الحالتين مايتلمسش)

   وبيتطبّق على اللي **نشط شهر واحد بس** — الصنف اللي له شهور نشطة
   أكتر معدله مبني على مدى أوسع أصلًا.

   ⚠️ **بينزل لـ1 مش لصفر** — عشان الصنف يفضل على الرف بواحدة، بقرار
      المالك. واستخدمنا `least(..., 1)` فالمعدل عمره ما **يعلى** بالقاعدة
      دي، ينزل بس.

   ── حدود التغطية ────────────────────────────────────────────────
   `sales_items` بيبدأ من **27 يوليو 2026**. فاللي بيعته أقدم من كده
   **مالوش فواتير فمابيتحكمش عليه** ومابيتغيّرش — 663 سطر من الـ1,056
   (132 ألف جنيه)، وساكسيندا منهم. القاعدة بتتطبّق على 393 سطر دلوقتي،
   وبتغطّي أكتر كل شهر مع تراكم الفواتير.

   ── الأثر المتوقع وقت الكتابة ───────────────────────────────────
   287 سطر «فاتورة واحدة» (35,635 جنيه) معدلهم هينزل لـ1 ·
   96 سطر «أكتر من فاتورة» (22,716 جنيه) هيفضلوا زي ما هم.

   ── التنفيذ ─────────────────────────────────────────────────────
   عدد الفواتير بيتخزّن في `consumption_flat.bills_<فرع>` وبيتمرّر لجدول
   الطلبيات في `sale_bills` — عشان الشاشة تفرّق بين «شاذ مؤكد» و«شغّال
   مؤكد» و«مالوش فواتير»، بدل ما تلوّن كل نشط-شهر-واحد أحمر.

   ⚠️ أسماء الفروع في `sales_items.store_name` **مش أسماء الفروع** —
      «الصيدلية» = المعمورة · «ابراهيم حمدي 2» = سان ستيفانو · «ابراهيم
      حمدي 3» = سيدى بشر. الربط من `branches.aliases` مش بالاسم المباشر.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) أعمدة عدد الفواتير ─────────────────────────────────────── */
do $$
declare r record;
begin
  for r in select * from public.branch_letters() loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='consumption_flat'
                      and column_name = 'bills_' || r.code) then
      execute format('alter table public.consumption_flat add column %I integer',
                     'bills_' || r.code);
    end if;
  end loop;
end $$;

alter table public.purchase_orders_flat add column if not exists sale_bills integer;

comment on column public.purchase_orders_flat.sale_bills is
  'عدد فواتير البيع للصنف في الفرع (من sales_items). NULL = مفيش فواتير في النافذة المتاحة.';

/* الفرع الجديد لازم ياخد عموده تلقائيًا زي باقي الأعمدة */
create or replace function public.sync_branch_sales_columns()
returns text
language plpgsql
as $fn$
declare
  r     record;
  v_add text := '';
  spec  record;
begin
  for r in select * from public.branch_letters() loop
    for spec in
      select * from (values
        ('monthly_sales',        r.code,               'numeric'),
        ('consumption_flat',     'av_'    || r.code,   'numeric'),
        ('consumption_flat',     'base_'  || r.code,   'numeric'),
        ('consumption_flat',     'act_'   || r.code,   'integer'),
        ('consumption_flat',     'sur_'   || r.code,   'numeric'),
        ('consumption_flat',     'bills_' || r.code,   'integer'),
        ('purchase_orders_flat', 'surplus_' || r.code, 'integer')
      ) as t(tbl, col, typ)
    loop
      if to_regclass('public.' || quote_ident(spec.tbl)) is not null
         and not exists (select 1 from information_schema.columns
                          where table_schema = 'public'
                            and table_name = spec.tbl and column_name = spec.col)
      then
        execute format('alter table public.%I add column %I %s', spec.tbl, spec.col, spec.typ);
        v_add := v_add || spec.tbl || '.' || spec.col || '  ';
      end if;
    end loop;
  end loop;
  return case when v_add = '' then 'مفيش أعمدة ناقصة' else 'اتضاف: ' || v_add end;
end
$fn$;

/* ── 2) المعدل: القاعدة جوّه المصدر الموحّد ────────────────────────
   ممنوع أي شاشة تحسب المعدل بنفسها، فالتصحيح لازم يتعمل هنا عشان
   الطلبيات والحد الأدنى والتقارير يشوفوا نفس الرقم. */
create or replace function public.get_consumption_rates()
returns setof public.consumption_flat
language plpgsql
as $fn$
declare
  f_base  text := '';
  f_rate  text := '';
  f_pass  text := '';
  f_agg   text := '';
  f_bill  text := '';   -- تجميعة عدد الفواتير لكل فرع (جوّه CTE الفواتير)
  f_bsel  text := '';   -- قراءة نفس الأعمدة بعد التجميع
  v_sel   text := '';
  v_drv   text := '';
  v_fin   text := '';
  v_join  text := '';
  v_extra text := '';
  v_tcode text;
  v_sd    text;   -- معدل المصدر في طبقة drv   (من الـjoin مباشرة)
  v_sf    text;   -- معدل المصدر في طبقة final (من أعمدة drv)
  v_tier  text;
  v_expr  text;
  v_sql   text;
  r       record;
  o       record;
  c       record;
begin
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

    /* عدد الفواتير لكل صنف في الفرع — الاسم في sales_items اسم بديل */
    f_bill := f_bill
      || ', count(distinct si.bill_no) filter (where si.br = ' || quote_literal(r.code) || ') bills_' || r.code;
    f_bsel := f_bsel || ', b.bills_' || r.code;
  end loop;

  for c in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'consumption_flat'
     order by ordinal_position
  loop
    if c.column_name like 'av\_%' or c.column_name like 'base\_%' then
      v_tcode := case when c.column_name like 'av\_%' then substr(c.column_name, 4)
                      else substr(c.column_name, 6) end;

      if c.column_name like 'av\_%' then
        v_expr := 'round(a.pre_' || v_tcode || ' * a.exc * coalesce((select t.multiply'
          || ' from public.category_rate_tiers t'
          || ' where t.category = a._cat'
          || '   and (t.branch is null or t.branch = ' || quote_literal(coalesce(
               (select bl.name from public.branch_letters() bl where bl.code = v_tcode),
               '')) || ')'
          || '   and a.pre_' || v_tcode || ' >= t.rate_min'
          || '   and a.act_' || v_tcode || ' >= t.active_min'
          || ' order by (t.branch is not null) desc, t.rate_min desc limit 1), 1), 1)';
      else
        v_expr := 'round(a.pre_' || v_tcode || ' * a.exc, 1)';
      end if;

      /* ═══ القاعدة ═══ نشط شهر واحد + فاتورة بيع واحدة = شاذ.
         least عشان مانعليش معدل أصلًا أقل من 1. */
      v_sel := v_sel
        || ', case when coalesce(a.act_'   || v_tcode || ', 0) = 1'
        || '        and coalesce(a.bills_' || v_tcode || ', 0) = 1'
        || '       then least(' || v_expr || ', 1)'
        || '       else ' || v_expr || ' end ' || quote_ident(c.column_name);
    else
      v_sel := v_sel || case
        when c.column_name = 'code'     then ', a.tcode'
        when c.column_name = 'itm_name' then
          ', coalesce(a.name_primary, (select nullif(s.n,'''') from stock_flat s where s.itm_code = a.tcode), a.name_any)'
        when c.column_name = 'refreshed_at' then ', now()'
        when c.column_name like 'act\_%'   then
          ', a.act_' || substr(c.column_name, 5) || '::int'
        when c.column_name like 'bills\_%' then
          ', a.bills_' || substr(c.column_name, 7) || '::int'
        when c.column_name like 'sur\_%'   then ', null::numeric'
        else ', null'
      end || ' ' || quote_ident(c.column_name);
    end if;
  end loop;

  for r in select * from public.branch_letters() loop
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
       'with amap as ('
    || '  select bl.code, unnest(b.aliases) alias'
    || '    from public.branch_letters() bl'
    || '    join public.branches b on b.name = bl.name'
    || '), bills as ('
    || '  select si.itm_code' || f_bill
    || '    from (select s.itm_code, s.bill_no, m.code br'
    || '            from sales_items s join amap m on m.alias = s.store_name'
    || '           where s.itm_qty > 0) si'
    || '   group by si.itm_code'
    || '), base as ('
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
    || '), catted as ('
    || '  select a.*, coalesce((select public.item_category(s.co, s.med) from stock_flat s'
    || '                         where s.itm_code = a.tcode limit 1), ''cos'') _cat'
    || '    from agg a'
    || '), withbills as ('
    || '  select c.*' || f_bsel || ' from catted c'
    || '  left join bills b on b.itm_code = c.tcode'
    || '), raw as (select ' || v_sel || ', a._cat from withbills a'
    || '), drv as (select ' || v_drv || ', x._cat' || v_extra
    || '             from raw x' || v_join
    || '), final as (select ' || v_fin || ' from drv d'
    || ') select * from final';

  return query execute v_sql;
end
$fn$;

revoke all on function public.get_consumption_rates() from public, anon;
grant execute on function public.get_consumption_rates() to authenticated, service_role;

/* ── 3) تمرير عدد الفواتير لجدول الطلبيات ──────────────────────────
   الشاشة كانت بتلوّن كل «نشط شهر واحد» أحمر. دلوقتي محتاجة تفرّق:
   شاذ مؤكد (فاتورة واحدة) · شغّال مؤكد (أكتر) · مالوش فواتير. */
do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc
   where proname = 'get_purchase_orders' and pronamespace = 'public'::regnamespace;

  if position('bl_'' || r.code' in v_src) > 0 then
    raise notice 'get_purchase_orders اتعدّلت قبل كده — اتخطّت';
    return;
  end if;

  /* قراءة العمود الجديد مع باقي أعمدة المعدل */
  v_src := replace(v_src,
    '|| '', coalesce(cf.'' || quote_ident(''act_''  || r.code) || '',0) act_'' || r.code;',
    '|| '', coalesce(cf.'' || quote_ident(''act_''  || r.code) || '',0) act_'' || r.code'
    || E'\n      || '', cf.'' || quote_ident(''bills_'' || r.code) || '' bl_'' || r.code;');

  /* وتعبئة عمود sale_bills في الناتج */
  v_src := replace(v_src,
    'when c.column_name = ''active_months''  then ''c.act_'' || r.code',
    'when c.column_name = ''active_months''  then ''c.act_'' || r.code'
    || E'\n        when c.column_name = ''sale_bills''     then ''c.bl_''  || r.code');

  /* الاستبدال النصّي بيفشل بصمت لو الدالة اتغيّرت — ساعتها sale_bills
     بيفضل NULL والشاشة تفتكر إن مفيش فواتير. نوقف بدل ما نكمل غلط. */
  if position('bills_'' || r.code' in v_src) = 0
     or position('''sale_bills''' in v_src) = 0 then
    raise exception 'نص get_purchase_orders اتغيّر — الترحيل مالقاش مكان الإضافة. عدّلها يدويًا.';
  end if;

  execute 'create or replace function public.get_purchase_orders() returns setof public.purchase_orders_flat '
       || 'language plpgsql as $q$' || v_src || '$q$';
end $$;

revoke all on function public.get_purchase_orders() from public, anon;
grant execute on function public.get_purchase_orders() to authenticated, service_role;
