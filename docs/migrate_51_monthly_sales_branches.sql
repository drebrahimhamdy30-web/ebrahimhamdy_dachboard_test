-- ═══════════════════════════════════════════════════════════════════
-- أ-2 · خطوة ١: أعمدة الفروع في monthly_sales + get_sales_summary
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- سلسلة الاستهلاك والطلبيات كلها ثلاثية:
--   monthly_sales → get_consumption_rates → consumption_flat
--                 → get_purchase_orders  → purchase_orders_flat
-- الترحيل ده أول خطوة فيها: مصدر البيانات نفسه.
--
-- ⚠️ السيوف مالهاش مبيعات (الفرع ما فتحش)، فكل النواتج هتفضل أصفار
--   مهما عملنا. يعني **مفيش طريقة نتأكد من أرقام السيوف** دلوقتي.
--   الضمان اللي بنشتغل بيه بدلها: ناتج الفروع التلاتة القديمة لازم
--   يطلع **مطابق بالحرف** قبل وبعد — وده اللي بنقيسه بالـmd5.
--
-- القرار: أعمدة عريضة بأسماء أكواد الفروع، بتتعمل من جدول الفروع
--   بـdynamic SQL — نفس نمط stock_flat، عشان مانخترعش أسلوب تالت.
--   البديل (الشكل الطولي) أنضف بس بيلمس رفع ملفات المبيعات وتاريخ
--   66 ألف صف، ومش وقته في نفس خطوة إضافة فرع.
-- ═══════════════════════════════════════════════════════════════════

-- ── ١) أعمدة الفروع تتعمل لوحدها ─────────────────────────────────
-- بتتنادى في الترحيل ده، ولازم تتنادى تاني بعد إضافة أي فرع جديد.
create or replace function public.sync_branch_sales_columns()
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
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
        ('consumption_flat',     'av_'   || r.code,    'numeric'),
        ('consumption_flat',     'base_' || r.code,    'numeric'),
        ('consumption_flat',     'act_'  || r.code,    'integer'),
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
end $fn$;

revoke all on function public.sync_branch_sales_columns() from public, anon;
grant execute on function public.sync_branch_sales_columns() to service_role;

select public.sync_branch_sales_columns() as الأعمدة;


-- ── ٢) ملخّص المبيعات: الأعمدة من جدول الفروع ────────────────────
-- الشاشات بتقرا <كود الفرع>_total و <كود الفرع>_active، وهي أصلًا
-- بتبنيهم بالكود (row[k+'_total'])، فالشكل مايتغيّرش — بيزيد بس.
create or replace function public.get_sales_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_sel  text := '';
  v_rows jsonb;
  r      record;
begin
  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      v_sel := v_sel
        || ', sum('   || quote_ident(r.code) || ') as ' || quote_ident(r.code || '_total')
        || ', count(*) filter (where ' || quote_ident(r.code) || ' > 0) as '
        || quote_ident(r.code || '_active');
    else
      -- الفرع متسجّل بس عموده لسه ماتعملش → أصفار **ظاهرة** بدل مفتاح
      -- ناقص تفضل الشاشة تقراه undefined وتحطّه صفر من غير ما حد يعرف.
      v_sel := v_sel
        || ', 0::numeric as ' || quote_ident(r.code || '_total')
        || ', 0::bigint  as ' || quote_ident(r.code || '_active');
    end if;
  end loop;

  execute
    'select coalesce(jsonb_agg(t), ''[]''::jsonb) from ('
    || ' select itm_code, max(itm_name) as itm_name' || v_sel
    || '   from monthly_sales group by itm_code) t'
    into v_rows;

  return v_rows;
end $fn$;

-- الصلاحيات زي ما كانت
grant execute on function public.get_sales_summary() to public, anon, authenticated;

notify pgrst, 'reload schema';
