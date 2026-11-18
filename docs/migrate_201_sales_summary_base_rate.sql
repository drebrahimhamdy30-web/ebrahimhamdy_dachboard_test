-- ٢٠١: إضافة «معدل الاستهلاك الخام» (base) لمخرجات get_sales_summary
--
-- الليه: شاشة «بحث في المخزون» كانت بتعرض `<الفرع>_av` تحت اسم «معدل
-- الاستهلاك»، و`av_` مش معدل استهلاك — ده **هدف الشراء** = الاستهلاك
-- مضروب في شريحة الفئة (`category_rate_tiers`). مثال تيمبو كول (كوزمو،
-- معدل ≥١٠ → ×٢): الشاشة بتقول ١٠٣.٣ والاستهلاك الحقيقي ٥١.٦.
-- النتيجة إن الواحد يقرا التغطية غلط (شهر ونص بدل ٣ شهور).
--
-- الحل: نطلّع الرقمين من نفس المصدر. `consumption_flat.base_<فرع>` هو
-- الخام وموجود أصلًا، فمحتاجين نمرّره بس.
--
-- ⚠️ ممنوع الشاشة تحسب المعدل بنفسها (مبيعات ÷ شهور نشطة) — ده كان
-- بيخلّيها تالت مصدر مختلف للمعدل في السيستم، والفرع الجديد كان معدله
-- صفر فيبان مخزونه كله زائد. التعليق في inventory_management.html
-- محذّر من ده بالنص.
--
-- ⚠️ الكاش: الدالة بتخزّن المخرجات في sales_summary_cache بمفتاح بصمة
-- مصادر البيانات. شكل المخرجات اتغيّر، فلو سبنا البصمة زي ما هي هترجّع
-- النسخة القديمة من غير الأعمدة الجديدة ولا حد ياخد باله. ضفنا رمز
-- إصدار للبصمة عشان الكاش القديم مايطابقش.

begin;

create or replace function public.get_sales_summary()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_sel text := ''; v_rows jsonb; r record; v_fp text; v_out jsonb;
begin
  /* v2 = إصدار شكل المخرجات؛ أي تغيير في الأعمدة يزوّده عشان الكاش يتبطّل */
  select 'v2|' || coalesce((select max(ms.updated_at)::text from public.monthly_sales ms), '-')
      || '|' || (select count(*)::text from public.monthly_sales)
      || '|' || coalesce((select max(cf.refreshed_at)::text from public.consumption_flat cf), '-')
      || '|' || coalesce((select string_agg(bl.code, ',' order by bl.sort_order)
                            from public.branch_letters() bl), '-')
    into v_fp;

  select c.payload into v_out
    from public.sales_summary_cache c
   where c.id = 1 and c.src_fp = v_fp and c.payload is not null;
  if v_out is not null then return v_out; end if;

  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales' and column_name = r.code) then
      v_sel := v_sel || ', sum(ms.' || quote_ident(r.code) || ') as ' || quote_ident(r.code || '_total')
                     || ', count(*) filter (where ms.' || quote_ident(r.code) || ' > 0) as '
                     || quote_ident(r.code || '_active');
    else
      v_sel := v_sel || ', 0::numeric as ' || quote_ident(r.code || '_total')
                     || ', 0::bigint as '  || quote_ident(r.code || '_active');
    end if;
    v_sel := v_sel || ', max(coalesce(cf.' || quote_ident('av_' || r.code) || ', 0)) as ' || quote_ident(r.code || '_av')
                   || ', max(coalesce(cf.' || quote_ident('sur_' || r.code) || ', 0)) as ' || quote_ident(r.code || '_sur');
    /* الخام — بفحص وجود العمود، لأن فرع جديد ممكن يكون لسه ماتضافش في consumption_flat */
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='consumption_flat'
                  and column_name = 'base_' || r.code) then
      v_sel := v_sel || ', max(coalesce(cf.' || quote_ident('base_' || r.code) || ', 0)) as '
                     || quote_ident(r.code || '_base');
    else
      v_sel := v_sel || ', 0::numeric as ' || quote_ident(r.code || '_base');
    end if;
  end loop;

  execute 'select coalesce(jsonb_agg(t), ''[]''::jsonb) from ('
       || ' select ms.itm_code, max(ms.itm_name) as itm_name' || v_sel
       || ' from monthly_sales ms'
       || ' left join consumption_flat cf on cf.code = ms.itm_code'
       || ' group by ms.itm_code) t' into v_rows;

  insert into public.sales_summary_cache (id, src_fp, payload, built_at)
  values (1, v_fp, v_rows, now())
  on conflict (id) do update
    set src_fp = excluded.src_fp, payload = excluded.payload, built_at = excluded.built_at;

  return v_rows;
end
$function$;

commit;
