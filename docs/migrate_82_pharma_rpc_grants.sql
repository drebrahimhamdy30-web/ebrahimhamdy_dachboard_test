-- ═══════════════════════════════════════════════════════════════════
--  قفل دوال كتابة فارما على anon/authenticated
-- ═══════════════════════════════════════════════════════════════════
--  التلات دوال دي بيناديها الـedge function `pharma_sync` بمفتاح
--  **service_role** بس. بس كلهم كانوا سايبين منحة PUBLIC (`=X/postgres`
--  في proacl) — يعني أي حد بالمفتاح العام (اللي موجود في كل صفحة HTML)
--  يقدر:
--    · pharma_prices_upsert   → يكتب سعر/خصم لأي صنف بالاسم، **ويضيف
--                                صفوف جديدة** للمخزن
--    · pharma_codes_upsert    → يغيّر كود المورّد (يبوّظ زر النسخ وربط
--                                الطلبية)
--    · pharma_prices_finalize → يعلّم **الكتالوج كله** «غير متاح»
--  والنتيجة في الحالتين إن قرار «أرخص مخزن» في الطلبيات يتفسد من بره.
--
--  اتأكدنا قبل القفل إن مفيش حاجة تانية بتناديهم:
--    · الريبوهين: صفر نداء من الواجهة (grep على html/js)
--    · n8n: 73 workflow، صفر إشارة لأي اسم منهم (اتصدّروا واتفحصوا
--      2026-09-30 — الظاهر بس `pharmacyQty` و`pharmacy_balance` وهما
--      أسماء حقول مالهاش علاقة)
--    · pg_cron: الوظايف بتشتغل بدور postgres، مش متأثرة
--  والتلاتة عندهم منحة صريحة لـservice_role فالمزامنة مابتتكسرش.
--
--  ⚠️ التلات أسطر revoke مقصودة: على السيرفر الذاتي فيه تريجر بيدّي
--     أي دالة جديدة EXECUTE لـanon وauthenticated **مباشرةً**، و
--     `revoke from public` مابيشيلش منحة مباشرة لدور. راجع
--     [[selfhosted-wide-grants]].
--
--  التطبيق: القاعدتين. آمن يتعاد أكتر من مرة.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare f text;
begin
  foreach f in array array[
    'public.pharma_prices_upsert(jsonb)',
    'public.pharma_codes_upsert(jsonb)',
    'public.pharma_prices_finalize(timestamptz)'
  ]
  loop
    -- الدالة ممكن تكون مش موجودة على الذاتي — منعدّيها بدل ما نوقع
    if to_regprocedure(f) is null then
      raise notice 'مش موجودة، اتعدّت: %', f;
      continue;
    end if;
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from anon', f);
    execute format('revoke all on function %s from authenticated', f);
    execute format('grant execute on function %s to service_role', f);
    raise notice 'اتقفلت: %', f;
  end loop;
end $$;

-- التحقق: المفروض كلهم anon_can=false و svc_can=true
select p.proname,
       has_function_privilege('anon',         p.oid, 'EXECUTE') as anon_can,
       has_function_privilege('authenticated',p.oid, 'EXECUTE') as auth_can,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as svc_can
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('pharma_prices_upsert','pharma_codes_upsert',
                     'pharma_prices_finalize','pharma_prices_refresh')
 order by p.proname;
