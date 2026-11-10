-- ═══════════════════════════════════════════════════════════════════
--  أكواد الصفوف الشحيحة — بقايا تحميل تقرير الإكسل
-- ═══════════════════════════════════════════════════════════════════
--  2026-11-10 رمّمنا مخزون المعمورة من تقرير eplus (xlsx) بعد ما
--  الوركفلو القديم بدّل الجدول بنصّه. التقرير فيه الكود والاسم العربي
--  والشركة والكمية والسعر والوحدة — **ومافيهوش** الباركود ولا الاسم
--  الإنجليزي ولا علامة الدوا ولا ختم التعديل.
--
--  فالأصناف اللي ما كانتش موجودة عندنا قبل كده اتكتبت بصف **شحيح**:
--    190 صنف له رصيد (2,059 وحدة)  ·  ~4,400 برصيد صفر
--
--  الصفوف دي بتتصلّح لوحدها أول ما الصنف يتباع — الفرقي بيجيبه كامل
--  من eplus — بس ده ممكن ياخد شهور للصنف البطيء. الدالة دي بتدّي
--  قايمتهم عشان وركفلو `docs/n8n_stock_backfill.json` يجيبهم دفعة
--  واحدة بنفس النداء الخفيف.
--
--  ⚠️ الكميات متخزّنة **نص** في جداول المخزون، فأي تحويل لرقم لازم
--     يتحرس بـregex — صف واحد فيه نص غريب بيوقّع الدالة كلها.
--  ⚠️ الـ`limit` لازم يكون **جوّه** الاستعلام الفرعي: بره `jsonb_agg`
--     النتيجة صف واحد فالـlimit مابيعملش حاجة. (وقعت فيها في النسخة
--     الأولى.)
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.stock_incomplete_codes(
  p_branch     text,
  p_limit      int     default 500,
  p_with_stock boolean default true
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_tbl text;
  v_out jsonb;
begin
  select 'stock_' || bl.code into v_tbl
    from public.branch_letters() bl where bl.code = p_branch;
  if v_tbl is null then raise exception 'فرع غير معروف: %', p_branch; end if;
  if to_regclass('public.' || v_tbl) is null then
    raise exception 'جدول مخزون مش موجود: %', v_tbl;
  end if;

  /* علامة الصف الشحيح: مفيش باركود ولا اسم إنجليزي ولا ختم تعديل.
     الاسم العربي والسعر والوحدة موجودين فيه عادي — وعشان كده البحث
     في eplus بيمشي بالاسم (أطول من الكود غالبًا). */
  execute format(
    'select coalesce(jsonb_agg(jsonb_build_object(''code'', itm_code, ''name'', itm_name_ar)), ''[]''::jsonb) '
    'from (select itm_code, itm_name_ar '
    '        from (select itm_code, itm_name_ar, '
    '                     case when sto_qty_big ~ ''^-?[0-9]+(\.[0-9]+)?$'' '
    '                          then sto_qty_big::numeric else 0 end q '
    '                from public.%I '
    '               where coalesce(itm_name_en, '''') = '''' '
    '                 and coalesce(itnl_code, '''')   = '''' '
    '                 and coalesce(update_date, '''') = '''' ) z '
    '       where ($1 is false or z.q > 0) '
    '       order by z.q desc '     -- الأكبر رصيدًا الأول: الأهم يتصلّح حتى لو السقف قطع
    '       limit $2) w'
    , v_tbl)
    into v_out using p_with_stock, p_limit;

  return jsonb_build_object('branch', p_branch,
                            'count', jsonb_array_length(v_out),
                            'items', v_out);
end $$;

comment on function public.stock_incomplete_codes(text, int, boolean) is
  'أكواد الأصناف اللي صفّها شحيح (بلا باركود ولا اسم إنجليزي ولا ختم تعديل) — بقايا تحميل تقرير إكسل. الأكبر رصيدًا الأول.';

/* تُنادى بالمفتاح الخدمي من n8n بس. راجع [[anon-key-lockdown]]:
   PUBLIC بياخد EXECUTE افتراضيًا فأي دالة جديدة بتفتح الباب. */
revoke all on function public.stock_incomplete_codes(text, int, boolean) from public;
revoke all on function public.stock_incomplete_codes(text, int, boolean) from anon;
grant execute on function public.stock_incomplete_codes(text, int, boolean) to service_role;
