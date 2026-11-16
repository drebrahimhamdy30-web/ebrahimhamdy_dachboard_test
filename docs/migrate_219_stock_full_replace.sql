-- migrate_219: سحب المخزون الكامل — كتابة آمنة في خطوة واحدة (السحابة)
--
-- الليه: من 15/11 الـAPI بتاع eplus بيعمل فحص عند bconnect مع كل نداء، والفحص ده
-- بيفشل 5–10% وقت الشغل. الفرقي بيعمل ~160 نداء/ساعة لسان لوحده (نداء «رصيد» لكل
-- صنف اتغيّر)، فبيتعرّض للفشل ده كتير. السحب الكامل = نداءين للفرع. اتجرّب 16/11:
-- 19,336 صنف لسان مطابقين stock_san 100%.
--
-- ليه دالة ومش تبديل جداول زي «stock manual» القديم: التبديل بيقع لأن
-- v_stock_units_full معتمد على الجدول، ولو نجح كان بيمسح أعمدة الوحدات/الأسعار.
-- هنا: نفس الجدول، تحديث/إضافة/مسح في معاملة واحدة، والـview والصلاحيات زي ما هي.
--
-- المدخل مضغوط عشان الحجم: p_cols أسامي الأعمدة + p_rows مصفوفة صفوف (كل صف مصفوفة
-- قيم بنفس ترتيب p_cols). صفوف الأفرع التانية بتتشال بأسامي المخازن (branches.aliases).
--
-- حارس: لو عدد الأصناف الجاية أقل من p_min_ratio × الموجود → استثناء ومفيش كتابة
-- (رد ناقص من eplus مايفضّيش المخزون).
-- p_dry_run = true → يرجّع الأرقام (هيضيف/هيحدّث/هيمسح) من غير أي كتابة.
-- التحديث بس للصفوف اللي اتغيّرت فعلًا، فـupdated_at يفضل معناه «اتغيّر إمتى».

create or replace function public.stock_full_replace(
  p_branch    text,
  p_cols      text[],
  p_rows      jsonb,
  p_min_ratio numeric default 0.8,
  p_dry_run   boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tbl     text;
  v_stores  text[];
  v_cols    text;
  v_set     text;
  v_cmp_t   text;
  v_cmp_x   text;
  v_in      int;
  v_dup     int;
  v_cur     int;
  v_ins     int;
  v_upd     int;
  v_del     int;
  t0        timestamptz := clock_timestamp();
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows لازم تكون مصفوفة JSON';
  end if;
  if p_cols is null or array_position(p_cols, 'itm_code') is null
     or array_position(p_cols, 'sto_name') is null then
    raise exception 'p_cols لازم يكون فيها itm_code و sto_name';
  end if;

  select 'stock_' || bl.code, b.aliases
    into v_tbl, v_stores
    from public.branch_letters() bl
    join public.branches b on b.name = bl.name
   where bl.code = p_branch;
  if v_tbl is null or to_regclass('public.' || v_tbl) is null then
    raise exception 'فرع غير معروف أو جدول مخزون مش موجود: %', p_branch;
  end if;
  if v_stores is null or array_length(v_stores, 1) is null then
    raise exception 'الفرع % مالوش أسماء مخازن (branches.aliases)', p_branch;
  end if;

  -- أعمدة الجدول (من غير updated_at) — الجاية من eplus بس اللي تتكتب
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position),
         string_agg(quote_ident(column_name) || ' = excluded.' || quote_ident(column_name),
                    ', ' order by ordinal_position),
         string_agg('t.' || quote_ident(column_name), ', ' order by ordinal_position),
         string_agg('excluded.' || quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols, v_set, v_cmp_t, v_cmp_x
    from information_schema.columns
   where table_schema = 'public' and table_name = v_tbl
     and column_name <> 'updated_at'
     and column_name = any(p_cols);

  -- صف مصفوفة → سجل بنوع الجدول؛ فرع الوركفلو بس؛ كود فاضي يتشال
  drop table if exists _sfr_in;
  execute format($q$
    create temp table _sfr_in on commit drop as
    select (jsonb_populate_record(null::public.%I, o)).*
      from (select (select jsonb_object_agg(c.k, r.e -> (c.i - 1)::int)
                      from unnest($1) with ordinality as c(k, i)) as o
              from jsonb_array_elements($2) as r(e)) z
  $q$, v_tbl) using p_cols, p_rows;

  delete from _sfr_in where not (sto_name = any(v_stores))
                         or coalesce(btrim(itm_code), '') = '';
  update _sfr_in set itm_code = btrim(itm_code);

  -- الكود مش فريد في eplus أحيانًا (راجع itm-code-not-unique): نحتفظ بصف واحد ونعدّ
  select count(*) - count(distinct itm_code) into v_dup from _sfr_in;
  if v_dup > 0 then
    delete from _sfr_in a using _sfr_in b
     where a.itm_code = b.itm_code and a.ctid < b.ctid;
  end if;
  select count(*) into v_in from _sfr_in;

  execute format('select count(*) from public.%I', v_tbl) into v_cur;

  if v_in = 0 or v_in < ceil(v_cur * coalesce(p_min_ratio, 0.8)) then
    raise exception 'حارس السحب الكامل: جه % صنف لـ% والموجود % — أقل من % في المية، مفيش كتابة',
      v_in, p_branch, v_cur, round(coalesce(p_min_ratio, 0.8) * 100);
  end if;

  execute format('select count(*) from _sfr_in i where not exists
                    (select 1 from public.%I t where t.itm_code = i.itm_code)', v_tbl) into v_ins;
  execute format('select count(*) from public.%I t where not exists
                    (select 1 from _sfr_in i where i.itm_code = t.itm_code)', v_tbl) into v_del;
  execute format('select count(*) from public.%I t join _sfr_in excluded using (itm_code)
                   where (%s) is distinct from (%s)', v_tbl, v_cmp_t, v_cmp_x) into v_upd;

  if not p_dry_run then
    execute format('delete from public.%I t where not exists
                      (select 1 from _sfr_in i where i.itm_code = t.itm_code)', v_tbl);
    execute format(
      'insert into public.%I as t (%s, updated_at) select %s, now() from _sfr_in '
      'on conflict (itm_code) do update set %s, updated_at = now() '
      'where (%s) is distinct from (%s)',
      v_tbl, v_cols, v_cols, v_set, v_cmp_t, v_cmp_x);
  end if;

  return jsonb_build_object(
    'branch',   p_branch,
    'dry_run',  p_dry_run,
    'received', jsonb_array_length(p_rows),
    'kept',     v_in,
    'dup_codes', v_dup,
    'current',  v_cur,
    'insert',   v_ins,
    'update',   v_upd,
    'delete',   v_del,
    'ms',       round(extract(epoch from clock_timestamp() - t0) * 1000),
    'at',       now());
end $function$;

revoke all on function public.stock_full_replace(text, text[], jsonb, numeric, boolean) from public, anon, authenticated;
grant execute on function public.stock_full_replace(text, text[], jsonb, numeric, boolean) to service_role;
