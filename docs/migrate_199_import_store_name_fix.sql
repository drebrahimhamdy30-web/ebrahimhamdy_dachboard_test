/* ═══════════════════════════════════════════════════════════════════
   إصلاح: اسم المخزن في الرفع اليدوي كان اسم الفرع مش اسم مخزن eplus
   ═══════════════════════════════════════════════════════════════════
   أول تجربة حقيقية للرفع وقعت على:
     «ولا صف من 27879 لمخازن الفرع mamora (الصيدلية) — راجع الوركفلو»

   `stock_import_build` كان بيحط في `sto_name` اسم **الفرع**
   («المعمورة»)، و`upsert_branch_stock` بيفلتر الصفوف على **أسماء
   مخازن eplus** المخزّنة في `branches.aliases` («الصيدلية») —
   فرمى الـ٢٧٨٧٩ صف كلهم.

   ⚠️ الفرق ده مش شكلي: `sto_name` في جداول المخزون هو اسم المخزن
      جوّه eplus، وهو **مختلف عن اسم الفرع عندنا** في ٣ فروع من ٤:
        mamora → الصيدلية · san → ابراهيم حمدي 2
        bishr  → ابراهيم حمدي 3 · seyouf → السيوف
      سكربت `load_stock_xlsx.js` كان عنده الخريطة دي مكتوبة بالأيد،
      وأنا اشتقيتها غلط من `branches.name`.

   العلاج: ناخد الاسم من **الجدول نفسه** (`sto_name` الموجود فعلًا في
   صفوف الفرع) — ده المصدر اللي الحارس بيقارن بيه. ولو الجدول فاضي
   نرجع لـ`aliases[1]` ثم `name`.

   ✅ الحارس بتاع `upsert_branch_stock` هو اللي مسك الغلطة ومنع كتابة
      ٢٧ ألف صف بمخزن غلط. ماكانش فيه أي ضرر.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

do $mig$
declare
  d text;
  old_t constant text :=
       '  select b.name into v_store' || chr(10)
    || '    from branch_letters() bl join branches b on b.name = bl.name where bl.code = v_branch;';
  new_t constant text :=
       '  /* ⚠️ اسم مخزن eplus مش اسم الفرع — المصدر هو الصفوف الموجودة' || chr(10)
    || '     فعلًا، وهو اللي upsert_branch_stock بيفلتر عليه. */' || chr(10)
    || '  execute format(''select t.sto_name from public.%I t' || chr(10)
    || '                   where coalesce(btrim(t.sto_name), '''''''') <> '''''''' limit 1'', v_tbl)' || chr(10)
    || '    into v_store;' || chr(10)
    || '  if v_store is null then' || chr(10)
    || '    select coalesce(b.aliases[1], b.name) into v_store' || chr(10)
    || '      from branch_letters() bl join branches b on b.name = bl.name where bl.code = v_branch;' || chr(10)
    || '  end if;';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'stock_import_build';
  if d is null then raise exception 'stock_import_build مش موجودة'; end if;
  if position('aliases[1]' in d) > 0 then
    raise notice 'stock_import_build: متعدّلة قبل كده — تخطّي'; return;
  end if;
  if position(old_t in d) = 0 then
    raise exception 'stock_import_build: نمط اسم المخزن مش مطابق — راجع الدالة';
  end if;
  execute replace(d, old_t, new_t);
end $mig$;

notify pgrst, 'reload schema';
