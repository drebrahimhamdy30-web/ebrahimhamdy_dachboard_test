-- ═══════════════════════════════════════════════════════════════════
-- أ-2 · خطوة ٤: رفع مبيعات الشهر من جدول الفروع
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين** — وبعد migrate_51)
--
-- `upload_month_sales` كانت بتقرا `e->>'mamora'` و`'san'` و`'bishr'`
-- بالإيد، فأي عمود مبيعات لفرع جديد بيتجاهل **بالساكت**: الرفع ينجح،
-- والعدد يطلع صح، والعمود يفضل فاضي. وبعدها معدل الاستهلاك صفر
-- والطلبية تطلع غلط — ومحدش يربط السبب بالنتيجة.
--
-- المفاتيح أصلًا بأكواد الفروع، فالتعديل إن القايمة تتبني من
-- `branch_letters()` بدل ما تتكتب.
--
-- ملحوظة: لو الشاشة ما بعتتش مفتاح لفرع، بيتسجّل **صفر** مش null
--   (`coalesce(nullif(...),0)` زي الأصل). ده مقصود — صفر معناه «مفيش
--   مبيعات الشهر ده»، وحساب الشهور النشطة `filter (where col > 0)`
--   بيتعامل مع الاتنين بنفس الطريقة.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.upload_month_sales(p_month text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_ins  int;
  v_now  timestamptz := now();
  v_cols text := '';   -- أعمدة الفروع
  v_vals text := '';   -- قراءتها من الـjsonb
  v_sql  text;
  r      record;
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);
  if p_month is null or p_month !~ '^\d{2}-\d{4}$' then
    raise exception 'bad_month_format';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'rows_required';
  end if;

  for r in select * from public.branch_letters() loop
    -- الفرع اللي عموده لسه ماتعملش في monthly_sales بيتخطّى؛
    -- sync_branch_sales_columns() هي اللي بتعمله.
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      v_cols := v_cols || ', ' || quote_ident(r.code);
      v_vals := v_vals || ', coalesce(nullif(e->>' || quote_literal(r.code)
                       || ','''')::numeric, 0) ' || quote_ident(r.code);
    end if;
  end loop;

  if v_cols = '' then
    raise exception 'مفيش أعمدة فروع في monthly_sales — شغّل sync_branch_sales_columns()';
  end if;

  delete from monthly_sales where month = p_month;

  v_sql :=
       'with raw as ('
    || '  select trim(e->>''code'') itm_code, trim(e->>''name'') itm_name' || v_vals
    || '       , (row_number() over ())::int rn'
    || '    from jsonb_array_elements($1) e'
    || '), cleaned as (select * from raw where itm_code is not null and itm_code <> '''''
    || '), dedup as ('
    || '  select distinct on (itm_code) itm_code, itm_name' || v_cols
    || '    from cleaned order by itm_code, rn desc'
    || ')'
    || ' insert into monthly_sales(itm_code, itm_name' || v_cols || ', month, updated_at)'
    || ' select itm_code, itm_name' || v_cols || ', $2, $3 from dedup';

  execute v_sql using p_rows, p_month, v_now;
  get diagnostics v_ins = row_count;

  perform refresh_consumption_rates();
  return jsonb_build_object('month', p_month, 'inserted', v_ins);
end $fn$;

-- الصلاحيات زي ما كانت
grant execute on function public.upload_month_sales(text, jsonb) to public, anon, authenticated;

notify pgrst, 'reload schema';
