/* ═══════════════════════════════════════════════════════════════════
   البحث السريع: الكود يتطابق بدل ما يتضمّن
   ═══════════════════════════════════════════════════════════════════
   البحث بـ«7008» في شريط البحث كان بيرجّع أصناف كودها **67008** —
   لأن الفلتر كان `code ilike '%7008%'`. على البيانات الحقيقية:
   ٦ صفوف كودها 67008 مقابل صفّين بس كودهم 7008 الحقيقي، يعني
   المطلوب كان مدفون تحت نتايج مالهاش علاقة.

   الكود حاجة بتتقرا من العلبة أو الفاتورة — المطابقة الجزئية فيه
   ضوضاء مش مساعدة. الاسم فاضل بحث جزئي زي ما هو.

   ── الثلاث أوضاع ────────────────────────────────────────────────
   • «المخازن» (فلتر PostgREST في الشل): `ilike '%q%'` → `eq`
     دي اللي كانت بترجّع 67008. التعديل في `delivery/app.html`.
   • «المخزون» (`quick_search_stock`): كان `starts_with` → مطابقة.
   • «التكلفة» (`search_item_cost`): كان `= v_q OR like v_q||'%'`
     → `= v_q` بس.

   ── ليه التعديل بـpg_get_functiondef مش نص الدالة كامل ──────────
   الدالتين ~٣ كيلوبايت لكل واحدة والتغيير سطر واحد في كل منهم.
   إعادة كتابتهم كاملين في الترحيل = مخاطرة نسخ على شغل مش محتاج
   يتغيّر. فبنقرا التعريف الحالي من القاعدة، نستبدل الشرط، وننفّذ.

   ⚠️ **وفيه حارس**: لو النمط مش موجود **بالظبط مرة واحدة** الترحيل
      بيقع برسالة واضحة بدل ما يعدّي من غير ما يغيّر حاجة. ده اللي
      بيخلّي الطريقة دي آمنة — من غيره كان ممكن يمشي صامت على قاعدة
      الدالة فيها متغيّرة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ─── المخزون: البادئة → مطابقة تامة ─────────────────────────────── */
do $$
declare d text; n int;
  pat_old constant text := 'starts_with(lower(f.itm_code), lower(v_q))';
  pat_new constant text := 'lower(btrim(f.itm_code)) = lower(v_q)';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'quick_search_stock';
  if d is null then
    raise exception 'quick_search_stock مش موجودة على القاعدة دي';
  end if;
  if position(pat_new in d) > 0 then
    raise notice 'quick_search_stock: متعدّلة قبل كده — تخطّي';
    return;
  end if;
  select count(*) into n from regexp_matches(d, 'starts_with\(lower\(f\.itm_code\), lower\(v_q\)\)', 'g');
  if n <> 1 then
    raise exception 'quick_search_stock: النمط اتلقى % مرة مش مرة واحدة — راجع الدالة', n;
  end if;
  execute replace(d, pat_old, pat_new);
end $$;

/* ─── التكلفة: شيل شرط البادئة وسيب المطابقة ─────────────────────── */
do $$
declare d text; d2 text; n int;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'search_item_cost';
  if d is null then
    raise exception 'search_item_cost مش موجودة على القاعدة دي';
  end if;
  select count(*) into n from regexp_matches(d, 'or c\.itm_code like v_q \|\| ''%''', 'g');
  if n = 0 then
    raise notice 'search_item_cost: متعدّلة قبل كده — تخطّي';
    return;
  end if;
  if n <> 1 then
    raise exception 'search_item_cost: النمط اتلقى % مرة مش مرة واحدة — راجع الدالة', n;
  end if;
  d2 := regexp_replace(d, '\s*or c\.itm_code like v_q \|\| ''%''', '');
  if d2 = d then
    raise exception 'search_item_cost: الاستبدال ما غيّرش حاجة';
  end if;
  execute d2;
end $$;

notify pgrst, 'reload schema';
