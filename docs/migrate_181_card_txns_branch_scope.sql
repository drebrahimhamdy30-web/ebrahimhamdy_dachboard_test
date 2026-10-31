/* ════════════════════════════════════════════════════════════════
   حارس الفرع لـget_card_txns   (2026-10-31)
   ----------------------------------------------------------------
   **اللي اتكشف**: وأنا بشيل فلتر الفرع المكرر من تبويب «مراجعة تحصيل
   بطاقات الائتمان» لقيت إن الدالة بتمرّر `p_branch` زي ما هو:

       and (p_branch is null or c.branch = p_branch)

   يعني **أي حد يقدر يفتح التبويب ويبعت فرع فاضي ياخد كل الفروع**.
   الخطر نظري دلوقتي لأن التبويب مقصور على الأدمن (migrate_167)، بس
   أول ما يتدّي لمدير فرع من شاشة الصلاحيات هيشوف أرقام كل الفروع
   من غير ما حد ياخد باله — والإخفاء في الشاشة **مش حماية**، أي حد
   يقدر ينادي الدالة من الكونسول.

   نفس نمط باقي الشاشات ([[branch-scope-by-role]]): الأدمن ومن عنده
   `page_permissions.all_branches` لصفحة `current_shift` يشوفوا الكل،
   وغيرهم فرعهم بس — و**بارامتر الفرع بيتجاهل** لهم، فالقايمة مش
   بتتفتح بتغيير الفلتر.

   ⚠️ `cashier_transactions.branch` كود إنجليزي (mamora/san/…) مش
      اسم عربي، فالتحويل بـ`branch_code_of()`.

   التعديل **جراحي** على الدالة الموجودة (استبدال نصّي بحراسة) عشان
   مانعيدش كتابة دالة طويلة ونكسر حاجة فيها.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

do $do$
declare src text; nsrc text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_card_txns';
  if src is null then raise exception 'get_card_txns مش موجودة'; end if;
  if src like '%v_br text%' then raise notice 'الحارس متضاف قبل كده'; return; end if;

  /* ١) متغيّرات الحارس */
  nsrc := replace(src,
    'declare v_from date; v_to date; v_lim int; v_off int; v_out jsonb;',
    'declare v_from date; v_to date; v_lim int; v_off int; v_out jsonb;'
      || E'\n        v_br text; v_role text; v_all boolean;');
  if nsrc = src then raise exception 'مالقيتش سطر declare'; end if;
  src := nsrc;

  /* ٢) حساب النطاق قبل أي استعلام */
  nsrc := replace(src,
    '  v_from := coalesce(p_from, (now() at time zone ''Africa/Cairo'')::date);',
    E'  /* نطاق الفرع: الأدمن ومن عنده all_branches يشوف الكل، وغيره\n'
      || E'     فرعه بس — وبارامتر الفرع بيتجاهل له. */\n'
      || E'  v_role := public.jwt_app_role();\n'
      || E'  if coalesce(current_setting(''request.jwt.claims'', true)::jsonb ->> ''role'','''') = ''service_role''\n'
      || E'     or v_role = ''admin'' then\n'
      || E'    v_br := nullif(btrim(coalesce(p_branch,'''')),'''');\n'
      || E'  else\n'
      || E'    select pp.all_branches into v_all from page_permissions pp\n'
      || E'     where pp.role = v_role and pp.page_key = ''current_shift'';\n'
      || E'    if coalesce(v_all, false) then\n'
      || E'      v_br := nullif(btrim(coalesce(p_branch,'''')),'''');\n'
      || E'    else\n'
      || E'      v_br := coalesce(public.branch_code_of(public.jwt_branch()), ''__none__'');\n'
      || E'    end if;\n'
      || E'  end if;\n'
      || '  v_from := coalesce(p_from, (now() at time zone ''Africa/Cairo'')::date);');
  if nsrc = src then raise exception 'مالقيتش سطر v_from'; end if;
  src := nsrc;

  /* ٣) الشرط يستعمل النطاق بدل البارامتر الخام */
  nsrc := replace(src,
    'and (p_branch is null or c.branch = p_branch)',
    'and (v_br is null or c.branch = v_br)');
  if nsrc = src then raise exception 'مالقيتش شرط الفرع'; end if;

  execute nsrc;
  raise notice 'اتضاف حارس الفرع لـget_card_txns';
end $do$;

/* ── تحقق بعد التطبيق ───────────────────────────────────────
   افتح التبويب بحساب أدمن وتأكد إن «كل الفروع» لسه بترجّع الأربعة،
   وبحساب مدير فرع تأكد إنها بترجّع فرعه بس. */
