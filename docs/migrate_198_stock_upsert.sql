-- ═══════════════════════════════════════════════════════════════════
--  مزامنة المخزون بالتحديث المباشر بدل استبدال الجدول
-- ═══════════════════════════════════════════════════════════════════
--  الوركفلو الحالي بيستبدل الجدول كله كل ساعة:
--    Drop & Create Staging → نداءين ضخام (كوزمو/أدوية) → إدراج صف‑بصف
--    → Merge (wait for both) → Swap Tables
--
--  وكل أعطالنا طلعت من الخطوات دي بالذات:
--   · `Drop & Create Staging` → جدول فاضي قابل للتبديل = حادثة سيدى بشر
--   · الرد الضخم (27,821 صف) → قطع كلاودفلير عند 100 ثانية (المعمورة
--     وقفت 7 ساعات 2026-11-09 وسابت 12,330 صف في المرحلة)
--   · `Merge (wait for both)` → فرع يعلّق فالدمج يستنى للأبد بالساكت
--   · `Swap Tables` (rename) → بيموّت أي تريجر/view على الجدول، وعشان
--     كده كان ممنوع نعمل view على جداول المخزون
--
--  ── الاكتشاف اللي خلّى التحويل ممكن (2026-11-10) ──
--  `last_trans_date` اللي الـAPI بيرجّعه = ختم جدول التدقيق
--  `watch_qty_chng` في eplus (سجل كل تغيّر كمية). اتأكد بالعدّ المطابق
--  في تلات نوافذ: النهاردة 622=622 · 7 أيام 3992=3992 · 30 يوم
--  8698=8698.
--
--  وبمقارنة `Item_Daily_Stock` (لقطة الرصيد اليومية في eplus) بالفلتر:
--    يوم · يومين · 7 أيام · 30 يوم  →  **صفر صنف فات**
--    (30 يوم: 6,531 صنف رصيده اتغيّر، الفلتر علّم 8,587، فات صفر)
--  والأصناف الجديدة متغطّاة: 325 صنف دخل المخزون لأول مرة في أسبوع،
--  صفر منهم فات — لأن أول رصيد بيتسجّل كـ`Insert` في نفس السجل.
--
--  يعني التحديث الفرقي **مكافئ** للاستبدال الكامل، بـ~100 صف بدل
--  27,821. الحالة الوحيدة اللي محتاجة لقطة كاملة = **الصنف المحذوف**.
--
--  ── الملفّ ده بيدّي الطرف اللي في القاعدة ──
--  (١) `upsert_branch_stock(فرع, صفوف)` — تحديث أو إضافة، نداء واحد.
--  (٢) `sweep_branch_stock(فرع, منذ, سقف%)` — بديل التبديل في اللقطة
--      الليلية: امسح اللي ماتحدّثش في الجولة، **بحارس نسبة**.
--      أأمن من الاستبدال: الجلب لو وقع في النص، اللي وصل اتحدّث واللي
--      ماوصلش فضل بقيمته القديمة (مش صفر)، والحذف بيترفض.
--      ومفيش لحظة واحدة الجدول فيها ناقص.
--  (٣) تريجر `updated_at` على الجداول الأربعة.
--
--  ⚠️ التريجر بيموت مع أول `Swap Tables` (الجدول بيتستبدل بكيان تاني).
--     فالملف ده يتطبّق **مع** تحويل الوركفلو للـupsert، مش قبله.
-- ═══════════════════════════════════════════════════════════════════

-- ── (١) تحديث أو إضافة ─────────────────────────────────────────────
create or replace function public.upsert_branch_stock(p_branch text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tbl  text;
  v_cols text;   -- قائمة الأعمدة
  v_defs text;   -- تعريف الأعمدة لـjsonb_to_recordset
  v_set  text;   -- الإسناد عند التعارض
  v_n    int;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows لازم تكون مصفوفة JSON';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('branch', p_branch, 'rows', 0, 'affected', 0);
  end if;

  /* اسم الجدول بييجي من قائمة الفروع المعرّفة في القاعدة — مش من نص
     جاي مع النداء. ده اللي بيمنع الحقن في SQL الديناميكي. */
  select 'stock_' || bl.code into v_tbl
    from public.branch_letters() bl where bl.code = p_branch;
  if v_tbl is null then
    raise exception 'فرع غير معروف: %', p_branch;
  end if;

  /* الأعمدة بتتقرا من الجدول نفسه — فأي عمود جديد يتضاف مستقبلًا
     بيتظبط لوحده من غير ما حد يعدّل الدالة. */
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position),
         string_agg(quote_ident(column_name) || ' ' || data_type, ', ' order by ordinal_position),
         string_agg(quote_ident(column_name) || ' = excluded.' || quote_ident(column_name),
                    ', ' order by ordinal_position)
    into v_cols, v_defs, v_set
    from information_schema.columns
   where table_schema = 'public' and table_name = v_tbl
     and column_name <> 'updated_at';

  if v_cols is null then
    raise exception 'الجدول % مش موجود', v_tbl;
  end if;

  /* ⚠️ الأعمدة الغايبة من الـJSON بتتكتب NULL — فالنداء لازم يبعت
     الصف **كامل** زي ما الـAPI بيرجّعه، مش الحقول اللي اتغيّرت بس. */
  execute format(
      'insert into public.%I (%s, updated_at) '
      'select %s, now() from jsonb_to_recordset($1) as x(%s) '
      'on conflict (itm_code) do update set %s, updated_at = now()',
      v_tbl, v_cols, v_cols, v_defs, v_set)
    using p_rows;
  get diagnostics v_n = row_count;

  return jsonb_build_object('branch', p_branch,
                            'rows', jsonb_array_length(p_rows),
                            'affected', v_n,
                            'at', now());
end $$;

comment on function public.upsert_branch_stock(text, jsonb) is
  'تحديث أو إضافة أصناف مخزون فرع من مصفوفة JSON. بديل دورة المرحلة والتبديل.';

-- ── (٢) بديل التبديل في اللقطة الكاملة ─────────────────────────────
create or replace function public.sweep_branch_stock(
  p_branch   text,
  p_since    timestamptz,
  p_max_pct  numeric default 10,
  p_apply    boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tbl   text;
  v_total int;
  v_old   int;
  v_pct   numeric;
  v_n     int := 0;
begin
  select 'stock_' || bl.code into v_tbl
    from public.branch_letters() bl where bl.code = p_branch;
  if v_tbl is null then raise exception 'فرع غير معروف: %', p_branch; end if;

  execute format('select count(*) from public.%I', v_tbl) into v_total;
  execute format('select count(*) from public.%I where updated_at < $1', v_tbl)
    into v_old using p_since;

  v_pct := case when v_total > 0 then round(100.0 * v_old / v_total, 2) else 0 end;

  /* الحارس: جولة كاملة سليمة بتسيب نسبة صغيرة جدًا (أصناف اتمسحت من
     eplus). نسبة كبيرة = الجلب نفسه ناقص — ساعتها مانحذفش، نسيب
     القديم الصح مكانه. */
  if v_old = 0 then
    return jsonb_build_object('branch', p_branch, 'total', v_total,
      'stale', 0, 'pct', 0, 'deleted', 0, 'result', 'nothing_to_sweep');
  end if;

  if v_pct > p_max_pct then
    return jsonb_build_object('branch', p_branch, 'total', v_total,
      'stale', v_old, 'pct', v_pct, 'deleted', 0, 'result', 'refused',
      'reason', format('%s%% أكبر من السقف %s%% — الجلب غالبًا ناقص', v_pct, p_max_pct));
  end if;

  if not p_apply then
    return jsonb_build_object('branch', p_branch, 'total', v_total,
      'stale', v_old, 'pct', v_pct, 'deleted', 0, 'result', 'dry_run');
  end if;

  execute format('delete from public.%I where updated_at < $1', v_tbl)
    using p_since;
  get diagnostics v_n = row_count;

  return jsonb_build_object('branch', p_branch, 'total', v_total,
    'stale', v_old, 'pct', v_pct, 'deleted', v_n, 'result', 'swept');
end $$;

comment on function public.sweep_branch_stock(text, timestamptz, numeric, boolean) is
  'بعد لقطة كاملة: امسح الأصناف اللي ماتحدّثتش في الجولة، بحارس نسبة. p_apply=false معاينة.';

revoke all on function public.upsert_branch_stock(text, jsonb) from public;
revoke all on function public.sweep_branch_stock(text, timestamptz, numeric, boolean) from public;
grant execute on function public.upsert_branch_stock(text, jsonb) to authenticated, service_role;
grant execute on function public.sweep_branch_stock(text, timestamptz, numeric, boolean) to authenticated, service_role;

-- ── (٣) ختم updated_at صادق ────────────────────────────────────────
--  DEFAULT now() بيشتغل عند الإضافة **بس**. من غير التريجر ده:
--   · تنبيه التأخّر بيقرا max(updated_at) فيبان الجدول واقف وهو حيّ
--   · والكنس في (٢) هيحذف صفوف اتحدّثت فعلًا
--  (نفس الفخ اللي خلّى أرصدة الموردين تبان واقفة شهر وهي مظبوطة)
do $$
declare r record;
begin
  for r in select bl.code from public.branch_letters() bl loop
    if to_regclass('public.stock_' || r.code) is not null then
      execute format('drop trigger if exists trg_touch_updated_at on public.%I', 'stock_' || r.code);
      execute format(
        'create trigger trg_touch_updated_at before update on public.%I '
        'for each row execute function public.touch_updated_at()', 'stock_' || r.code);
      raise notice 'تريجر stock_%', r.code;
    end if;
  end loop;
end $$;

-- ── (٤) فحص ────────────────────────────────────────────────────────
do $$
declare v jsonb;
begin
  v := public.sweep_branch_stock('mamora', now() - interval '100 years', 10, false);
  if v->>'result' <> 'nothing_to_sweep' then
    raise exception 'الفحص فشل: %', v;
  end if;
  raise notice 'sweep dry-run تمام: %', v;
end $$;

notify pgrst, 'reload schema';
