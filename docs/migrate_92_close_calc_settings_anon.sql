/* ═══════════════════════════════════════════════════════════════════
   قفل جدولي إعدادات الحساب على anon
   ═══════════════════════════════════════════════════════════════════
   تصحيح لسهو في migrate_85: `branch_calc_settings` و
   `category_rate_tiers` اتمنحوا `select` لـanon وقت إنشائهم، والحقيقة
   إن الشاشتين الوحيدتين اللي بيقروهم — «إعدادات المؤسسة» وعرض قواعد
   الطلب في شاشة الكوزمو — **الاتنين ورا تسجيل دخول**.

   مش بيانات حساسة (إعدادات حساب معدل)، بس مفيش سبب تكون مكشوفة،
   والقاعدة بعد 89/90: anon مايشوفش غير اللي لازم قبل الدخول.

   بعده anon يقرا 5 جداول بس: branches · org_settings · app_pages ·
   app_control · driver_app_version — وكلهم مطلوبين قبل الدخول فعلًا.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

do $$
declare t text;
begin
  foreach t in array array['branch_calc_settings','category_rate_tiers']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_auth_all', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true)',
      t || '_auth_all', t);
  end loop;
end $$;

select c.relname as الجدول,
       has_table_privilege('anon', c.oid, 'SELECT')          as anon_يقرا,
       has_table_privilege('authenticated', c.oid, 'SELECT') as المسجّل_يقرا
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in ('branch_calc_settings','category_rate_tiers');
