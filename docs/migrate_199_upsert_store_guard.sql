-- ═══════════════════════════════════════════════════════════════════
--  حارس المخزن في upsert_branch_stock
-- ═══════════════════════════════════════════════════════════════════
--  🛑 اتكشف 2026-11-10 أثناء تجربة أول نداء فرقي:
--  نداء `SearchItem` من غير فلتر مخزن بيرجّع **كل المخازن**، مش مخزن
--  الفرع اللي بنسأل عنه. أول صف في رد المعمورة كان:
--      itm_code=sr10 · sto_name=«ابراهيم حمدي 2» · sto_qty_big=304.82
--  وده مخزن **سان ستيفانو**.
--
--  والفهرس الفريد على `stock_<فرع>` على **`itm_code` لوحده** (مفيش
--  مخزن فيه، لأن كل جدول كان المفروض فيه مخزن واحد). فالصف ده كان
--  هيعمل `on conflict do update` على صف المعمورة **ويحط فيه رصيد
--  سان**. بالساكت، وبأرقام تبان معقولة تمامًا.
--
--  ده أخطر من الجدول الفاضي: الفاضي بيصرخ (كل حاجة صفر)، وده
--  بيعدّي من غير ما حد يشك.
--
--  الوركفلو القديم كان بيفلتر في عقدة `Code in JavaScript` قبل
--  الإدراج. والاعتماد على فلتر في الواجهة معناه إنه لازم يتكرر صح في
--  ٤ وركفلوهات، وأول واحد يتنسي = بيانات متلخبطة. **الحارس مكانه
--  الدالة.**
--
--  المصدر: `branches.aliases` — نفس المصدر اللي `get_consumption_rates`
--  بيستخدمه لربط اسم المخزن بالفرع، مش قايمة جديدة تتصان لوحدها:
--      المعمورة → الصيدلية · سان → ابراهيم حمدي 2
--      سيدى بشر → ابراهيم حمدي 3 · السيوف → السيوف
--
--  والرد بقى بيقول **كام صف اتقبل وكام اتشال** — مش بيشيل بالساكت.
--  ولو الحمولة فيها صفوف ومفيش ولا واحد لمخزن الفرع → **استثناء**،
--  لأن ده معناه وركفلو بينده على الفرع الغلط.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.upsert_branch_stock(p_branch text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tbl     text;
  v_cols    text;
  v_defs    text;
  v_set     text;
  v_stores  text[];
  v_has_sto boolean;
  v_n       int;
  v_total   int;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows لازم تكون مصفوفة JSON';
  end if;
  v_total := jsonb_array_length(p_rows);
  if v_total = 0 then
    return jsonb_build_object('branch', p_branch, 'rows', 0, 'kept', 0, 'skipped', 0, 'affected', 0);
  end if;

  select 'stock_' || bl.code into v_tbl
    from public.branch_letters() bl where bl.code = p_branch;
  if v_tbl is null then
    raise exception 'فرع غير معروف: %', p_branch;
  end if;

  /* أسماء مخازن الفرع — من نفس مصدر باقي النظام */
  select b.aliases into v_stores
    from public.branch_letters() bl
    join public.branches b on b.name = bl.name
   where bl.code = p_branch;

  select string_agg(quote_ident(column_name), ', ' order by ordinal_position),
         string_agg(quote_ident(column_name) || ' ' || data_type, ', ' order by ordinal_position),
         string_agg(quote_ident(column_name) || ' = excluded.' || quote_ident(column_name),
                    ', ' order by ordinal_position),
         bool_or(column_name = 'sto_name')
    into v_cols, v_defs, v_set, v_has_sto
    from information_schema.columns
   where table_schema = 'public' and table_name = v_tbl
     and column_name <> 'updated_at';

  if v_cols is null then
    raise exception 'الجدول % مش موجود', v_tbl;
  end if;

  /* ⚠️ الأعمدة الغايبة من الـJSON بتتكتب NULL — فالنداء لازم يبعت
     الصف **كامل** زي ما الـAPI بيرجّعه. */
  if v_has_sto and v_stores is not null and array_length(v_stores, 1) > 0 then
    execute format(
        'insert into public.%I (%s, updated_at) '
        'select %s, now() from jsonb_to_recordset($1) as x(%s) '
        'where x.sto_name = any($2) '
        'on conflict (itm_code) do update set %s, updated_at = now()',
        v_tbl, v_cols, v_cols, v_defs, v_set)
      using p_rows, v_stores;
  else
    execute format(
        'insert into public.%I (%s, updated_at) '
        'select %s, now() from jsonb_to_recordset($1) as x(%s) '
        'on conflict (itm_code) do update set %s, updated_at = now()',
        v_tbl, v_cols, v_cols, v_defs, v_set)
      using p_rows;
  end if;
  get diagnostics v_n = row_count;

  /* حمولة فيها صفوف ومفيش ولا واحد لمخزن الفرع = الوركفلو بينده على
     الفرع الغلط. نوقف بصوت بدل ما نقول «تمام، صفر صف». */
  if v_n = 0 and v_total > 0 then
    raise exception 'ولا صف من الـ% لمخازن الفرع % (%) — راجع الوركفلو',
      v_total, p_branch, array_to_string(v_stores, ' / ');
  end if;

  return jsonb_build_object(
    'branch',  p_branch,
    'rows',    v_total,
    'kept',    v_n,
    'skipped', v_total - v_n,
    'stores',  to_jsonb(v_stores),
    'at',      now());
end $$;

comment on function public.upsert_branch_stock(text, jsonb) is
  'تحديث أو إضافة أصناف مخزون فرع من مصفوفة JSON، مع فلترة الصفوف على مخازن الفرع (branches.aliases).';

revoke all on function public.upsert_branch_stock(text, jsonb) from public;
grant execute on function public.upsert_branch_stock(text, jsonb) to authenticated, service_role;

-- ── فحص: صف من مخزن تاني لازم يترفض ────────────────────────────────
do $$
declare v jsonb; ok boolean := false; v_before numeric; v_after numeric;
begin
  select sto_qty_big::numeric into v_before from stock_mamora where itm_code = 'sr10';

  begin
    -- صف بمخزن سان ستيفانو مبعوت للمعمورة: لازم يترفض كله
    v := public.upsert_branch_stock('mamora',
           jsonb_build_array(jsonb_build_object(
             'itm_code', 'sr10', 'sto_name', 'ابراهيم حمدي 2',
             'sto_qty_big', '999999')));
  exception when others then ok := true;
  end;

  if not ok then
    raise exception 'الحارس ماشتغلش — صف من مخزن تاني عدّى! %', v;
  end if;

  select sto_qty_big::numeric into v_after from stock_mamora where itm_code = 'sr10';
  if v_before is distinct from v_after then
    raise exception 'الرصيد اتغيّر رغم الرفض: % ← %', v_before, v_after;
  end if;
  raise notice 'الحارس رفض صف المخزن الغلط والرصيد زي ما هو (%)', v_before;
end $$;

notify pgrst, 'reload schema';
