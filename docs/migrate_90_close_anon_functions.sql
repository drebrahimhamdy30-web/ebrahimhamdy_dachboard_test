/* ═══════════════════════════════════════════════════════════════════
   قفل دوال RPC على anon — الثغرة اللي كانت بتتخطى migrate_89
   ═══════════════════════════════════════════════════════════════════
   migrate_89 قفل الجداول، لكن الفحص (2026-10-04) أثبت إن ده **جزئي**:

     GET  /rest/v1/customers        →  401 ✅ (اتقفل)
     POST /rest/v1/rpc/get_customers →  200 ⚠️  3.9 ميجا بيانات عملاء
     POST /rest/v1/rpc/get_stock_summary → 200 ⚠️  6.7 ميجا بيانات مخزون

   السبب: بوستجرس بيمنح `EXECUTE` لـ**PUBLIC** افتراضيًا على أي دالة
   جديدة، و`anon` عضو في PUBLIC. و130 دالة منهم `SECURITY DEFINER`
   يعني بتتخطى RLS بطبيعتها. فالمفتاح العام (المنشور في ريبو عام)
   كان بيقرا كل حاجة من غير تسجيل دخول.

   ── اللي بيتعمل ──────────────────────────────────────────────────
   لكل دوال سكيما public: سحب EXECUTE من PUBLIC و anon، ومنحها
   صراحةً لـ authenticated و service_role.

   ── الاستثناءات (لازم تفضل مفتوحة لـanon) ───────────────────────
   اتحددت بجرد كل نداء RPC في الشاشتين والتطبيق وسكربتات tools:

     resolve_login_email       صفحة الدخول — بتحوّل اسم المستخدم لإيميل
     reset_password_with_code  استرجاع كلمة سر الطيار — قبل الدخول

     ibnsina_prices_upsert · ibnsina_prices_finalize · ibnsina_sync_report
     ibnsina_tax_upsert · ibnsina_avail_due · ibnsina_avail_upsert
       سكربتات tools/ على جهاز الصيدلية بتنادي بمفتاح anon، وكلها
       محروسة جوّه بـ`is_ibnsina_sync_key` فالمفتاح وحده مايكفيش.

   ── ليه تطبيق الطيار مش هيتأثر ──────────────────────────────────
   دخوله عبر n8n مش سوبابيز، فكان فيه شك في دور التوكن. الدليل:
   `get_trip_review_flags` **مقفولة على anon أصلًا** والتطبيق بينادیها
   وشغّال — يعني توكنه بيحمل دور `authenticated`. فباقي دواله
   (get_driver_month_stats · get_driver_rank · set_driver_avatar)
   آمنة في القفل.

   ── الأثر المتوقع ───────────────────────────────────────────────
   `sbH()` بترجع لمفتاح anon لو التوكن انتهى، فنداءات RPC هترجّع 401
   بدل بيانات في الحالة دي — وده الصح، و`sbFailMsg()` بيحوّلها لرسالة
   «جلستك انتهت». الشِل بيجدّد كل 5 دقايق فالحالة نادرة.

   الدوال اللي بتتنادى من pg_cron أو Edge Functions أو n8n مش متأثرة:
   دول بيشتغلوا بـservice_role أو اتصال مباشر بالقاعدة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

do $$
declare
  f    record;
  keep text[] := array[
    'resolve_login_email', 'reset_password_with_code',
    'ibnsina_prices_upsert', 'ibnsina_prices_finalize', 'ibnsina_sync_report',
    'ibnsina_tax_upsert', 'ibnsina_avail_due', 'ibnsina_avail_upsert'
  ];
  n_lock int := 0;
  n_keep int := 0;
begin
  for f in
    select p.oid,
           p.proname,
           p.oid::regprocedure::text as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
  loop
    /* PUBLIC هو اللي بيسرّب — anon عضو فيه. بنسحب الاتنين صراحةً. */
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon',   f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);

    if f.proname = any (keep) then
      execute format('grant execute on function %s to anon', f.sig);
      n_keep := n_keep + 1;
    else
      n_lock := n_lock + 1;
    end if;
  end loop;

  raise notice 'اتقفل على anon: % دالة · فضلت مفتوحة: %', n_lock, n_keep;
end $$;

/* ── التحقق ─────────────────────────────────────────────────────── */
select count(*) filter (where has_function_privilege('anon', p.oid, 'EXECUTE'))         as anon_لسه_ينفّذ,
       count(*) filter (where has_function_privilege('authenticated', p.oid,'EXECUTE')) as المسجّل_ينفّذ,
       count(*)                                                                          as إجمالي_الدوال
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f';

select p.proname as الدوال_المفتوحة_لـanon
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
   and has_function_privilege('anon', p.oid, 'EXECUTE')
 order by 1;
