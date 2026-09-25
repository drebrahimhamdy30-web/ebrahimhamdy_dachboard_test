-- ═══════════════════════════════════════════════════════════════════
-- أ-2 · خطوة ٢: معدل الاستهلاك من جدول الفروع
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين** — وبعد migrate_51)
--
-- `get_consumption_rates` كانت RETURNS TABLE بأعمدة ثابتة
-- (av_mamora, av_san, av_bishr …)، يعني الفرع الرابع لازم يتكتب
-- في التوقيع وفي تسع مواضع جوّه الحسبة.
--
-- الحل: بقت **`returns setof public.consumption_flat`**، والاستعلام
--   بيتبني بترتيب أعمدة الجدول نفسه. يعني العمود اللي
--   `sync_branch_sales_columns()` بتضيفه بيتحسب تلقائيًا من غير أي
--   تعديل هنا. مفيش توقيع لازم يتحدّث، ومفيش منطقين يتفارقوا.
--
-- ⚠️ التوقيع اتغيّر فمحتاج DROP. الشاشة بتقرا جدول consumption_flat
--   مباشرة (مش الدالة) وبتنادي refresh_consumption_rates بس —
--   اتأكدت من الريبوهين. الصلاحيات اترجّعت زي ما كانت بالحرف.
--
-- ⚠️ السيوف مالهاش مبيعات، فأعمدتها هتطلع أصفار. الضمان: قيم
--   الفروع التلاتة لازم تطلع **مطابقة بالحرف** قبل وبعد (md5).
-- ═══════════════════════════════════════════════════════════════════

drop function if exists public.get_consumption_rates();

create function public.get_consumption_rates()
returns setof public.consumption_flat
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  f_base  text := '';   -- المجاميع الشهرية لكل فرع
  f_rate  text := '';   -- المعدل الخام + عدد الشهور النشطة
  f_pass  text := '';   -- تمرير الأعمدة جوّه expanded
  f_agg   text := '';   -- التجميع بعد استبدال الأكواد
  v_sel   text := '';   -- قايمة الإخراج بترتيب أعمدة الجدول
  v_sql   text;
  r       record;
  c       record;
begin
  for r in select * from public.branch_letters() loop
    -- فرع متسجّل وعموده لسه ماتعملش في monthly_sales → أصفار
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

  -- الإخراج بترتيب أعمدة consumption_flat نفسها
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
        ', round(a.pre_' || substr(c.column_name, 4) || ' * a.exc * coalesce((select save_factor from demand_tiers t'
        || ' where a.pre_' || substr(c.column_name, 4) || ' >= t.rate_min'
        || '   and a.act_' || substr(c.column_name, 4) || ' >= t.active_min'
        || ' order by t.rate_min desc limit 1), 1), 1)'
      when c.column_name like 'base\_%' then
        ', round(a.pre_' || substr(c.column_name, 6) || ' * a.exc, 1)'
      -- ⚠️ ::int مقصود: count(distinct …) بترجّع bigint وعمود act_*
      --    في الجدول integer. plpgsql مابيفحصش ده وقت الإنشاء — الدالة
      --    بتتعمل وتقع وقت التشغيل بـ«structure of query does not match».
      when c.column_name like 'act\_%' then
        ', a.act_' || substr(c.column_name, 5) || '::int'
      else ', null'    -- عمود مش معروف: فاضي بدل ما الدالة تقع
    end;
  end loop;
  v_sel := ltrim(v_sel, ', ');

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
    || ') select ' || v_sel || ' from agg a';

  return query execute v_sql;
end $fn$;

-- الصلاحيات زي ما كانت بالحرف (PUBLIC + anon + authenticated)
grant execute on function public.get_consumption_rates() to public, anon, authenticated;


-- ── إعادة البناء: بقت select * لأن الدالة بترجّع شكل الجدول ──────
create or replace function public.refresh_consumption_rates()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare n int;
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    perform public.require_app_role(array['admin','manager','pharmacist']);
  end if;
  truncate consumption_flat;
  -- قايمة أعمدة صريحة كانت هتفضل ناقصة عمود الفرع الجديد؛ الدالة
  -- بقت ترجّع شكل الجدول نفسه فالنجمة كافية وصحيحة.
  insert into consumption_flat select * from public.get_consumption_rates();
  get diagnostics n = row_count;
  return n;
end $fn$;

grant execute on function public.refresh_consumption_rates() to public, anon, authenticated;

notify pgrst, 'reload schema';
