/* ═══════════════════════════════════════════════════════════════════
   البحث السريع: الاستعلام الرقمي = بحث كود وبس
   ═══════════════════════════════════════════════════════════════════
   بعد ما الكود بقى مطابقة تامة (migrate_196)، البحث بـ«7008» لسه
   بيرجّع نتيجتين:

     بلسم للكبار 120 ملل شراب — 7008    ← الكود (المطلوب)
     مناديل فاين 700 — 69705            ← **الاسم** فيه «700»

   التانية دي مش تطابق كود — دي مطابقة اسم بالتشابه. والمستخدم وهو
   بيكتب كود مش بيدوّر على أسماء فيها نفس الأرقام.

   ── القاعدة الجديدة ─────────────────────────────────────────────
   لو الاستعلام **كله أرقام** و**فيه كود مطابق موجود فعلًا** →
   النتيجة هي الكود ده وبس، ومطابقة الاسم بتتلغي.

   ⚠️ الشرط التاني مهم: لو مفيش كود بالرقم ده، البحث بالاسم بيفضل
      شغّال زي ما هو. يعني «120» لسه بتلاقي «بلسم 120 ملل» طالما
      مفيش صنف كوده 120 — ماكسرناش البحث بالاسم، قفلنا الضوضاء بس.

   ── التنفيذ ─────────────────────────────────────────────────────
   بدل ما نكرّر إسقاط الـ١١ عمود المعقّد بتاع `quick_search_stock`
   في مسار تاني، بنحسب علم `v_codeonly` مرة واحدة ونضيف شرط واحد
   على الناتج النهائي. الصف المطابق درجته 1.00 أصلًا فبيعدّي.

   ⚠️ التعديل بقراءة `pg_get_functiondef` واستبدال نصّي بحارس يقع
      لو النمط مش موجود بالظبط مرة واحدة — نفس أسلوب migrate_196،
      وبيتخطّى لو متعدّل قبل كده.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ─── المخزون ──────────────────────────────────────────────────── */
do $mig$
declare
  d text;
  a1_old constant text := '  ws  text[];' || chr(10) || 'begin';
  a1_new constant text := '  ws  text[];' || chr(10)
    || '  /* الاستعلام الرقمي اللي ليه كود موجود = بحث كود وبس */' || chr(10)
    || '  v_codeonly boolean := false;' || chr(10) || 'begin';
  a2_old constant text := '  perform set_limit(0.15);';
  a2_new constant text := '  if v_q ~ ''^[0-9]+$'' then' || chr(10)
    || '    select exists (select 1 from stock_flat f where btrim(f.itm_code) = v_q)' || chr(10)
    || '      into v_codeonly;' || chr(10)
    || '  end if;' || chr(10) || chr(10)
    || '  perform set_limit(0.15);';
  a3_old constant text :=
       '   where g.score >= 0.45' || chr(10)
    || '      or (g.n_strict < 5 and g.fw >= 0.90)' || chr(10)
    || '      or (g.n_strict = 0 and g.score >= 0.25)' || chr(10)
    || '   order by';
  a3_new constant text :=
       '   where (g.score >= 0.45' || chr(10)
    || '      or (g.n_strict < 5 and g.fw >= 0.90)' || chr(10)
    || '      or (g.n_strict = 0 and g.score >= 0.25))' || chr(10)
    || '     and (not v_codeonly or btrim(g.itm_code) = v_q)' || chr(10)
    || '   order by';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'quick_search_stock';
  if d is null then raise exception 'quick_search_stock مش موجودة'; end if;
  if position('v_codeonly' in d) > 0 then
    raise notice 'quick_search_stock: متعدّلة قبل كده — تخطّي'; return;
  end if;
  if (select count(*) from regexp_matches(d, '  ws  text\[\];\s*begin', 'g')) <> 1
     or position(a2_old in d) = 0
     or position(a3_old in d) = 0 then
    raise exception 'quick_search_stock: أنماط التعديل مش مطابقة — راجع الدالة';
  end if;
  d := replace(d, a1_old, a1_new);
  d := replace(d, a2_old, a2_new);
  d := replace(d, a3_old, a3_new);
  execute d;
end $mig$;

/* ─── التكلفة ──────────────────────────────────────────────────── */
do $mig$
declare
  d text;
  b1_old constant text := '  v_res jsonb;' || chr(10) || 'begin';
  b1_new constant text := '  v_res jsonb;' || chr(10)
    || '  /* الاستعلام الرقمي اللي ليه كود موجود = بحث كود وبس */' || chr(10)
    || '  v_codeonly boolean := false;' || chr(10) || 'begin';
  b2_old constant text := '  v_ws := array(select w from regexp_split_to_table(v_n, ''\s+'') w where length(w) > 1);';
  b3_old constant text := '     where c.itm_code = v_q' || chr(10)
    || '        or (select bool_and(ar_norm(c.itm_name) like ''%'' || w || ''%'') from unnest(v_ws) w)';
  b3_new constant text := '     where c.itm_code = v_q' || chr(10)
    || '        or (not v_codeonly' || chr(10)
    || '            and (select bool_and(ar_norm(c.itm_name) like ''%'' || w || ''%'') from unnest(v_ws) w))';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'search_item_cost';
  if d is null then raise exception 'search_item_cost مش موجودة'; end if;
  if position('v_codeonly' in d) > 0 then
    raise notice 'search_item_cost: متعدّلة قبل كده — تخطّي'; return;
  end if;
  if position(b1_old in d) = 0 or position(b2_old in d) = 0 or position(b3_old in d) = 0 then
    raise exception 'search_item_cost: أنماط التعديل مش مطابقة — راجع الدالة';
  end if;
  d := replace(d, b1_old, b1_new);
  d := replace(d, b2_old, b2_old || chr(10) || chr(10)
       || '  if v_q ~ ''^[0-9]+$'' then' || chr(10)
       || '    select exists (select 1 from purchase_invoice_items pi where pi.itm_code = v_q)' || chr(10)
       || '      into v_codeonly;' || chr(10)
       || '  end if;');
  d := replace(d, b3_old, b3_new);
  execute d;
end $mig$;

notify pgrst, 'reload schema';
