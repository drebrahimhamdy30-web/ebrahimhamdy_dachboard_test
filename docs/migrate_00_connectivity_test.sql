-- ═══════════════════════════════════════════════════════════════════
-- خطوة 0: هل السيرفر يقدر يوصل لسحابة Supabase؟
-- ═══════════════════════════════════════════════════════════════════
-- شغّل ده في SQL Editor بتاع supabase.ebrahimhamdy.com (مش السحابة).
--
-- الهدف: نعرف إذا كان ينفع ننقل البيانات **مباشرة** من السحابة للسيرفر
-- عن طريق postgres_fdw — من غير ملفات ولا رفع ولا تنزيل. لو ده اشتغل،
-- نقل الـ629 ميجا بيبقى استعلامات SQL عادية وخلاص.
--
-- ⚠️ غيّر <كلمة-سر-قاعدة-السحابة> بكلمة السر بتاعة قاعدة بيانات مشروع
--    السحابة. تلاقيها في: supabase.com → المشروع → Settings → Database
--    (لو مش فاكرها، من نفس الصفحة "Reset database password").
--    ماتبعتش الكلمة دي لحد — بتتكتب هنا على سيرفرك بس.
--
-- ⚠️ الأمر ده **مابيغيّرش أي حاجة** — بيقرا صف واحد للتجربة.
-- ═══════════════════════════════════════════════════════════════════

-- 1) الإضافات المطلوبة (موجودة في صورة Supabase الرسمية)
create extension if not exists postgres_fdw;
create extension if not exists dblink;

-- 2) تعريف السحابة كمصدر خارجي
--    بنستعمل الـ«session pooler» على 5432 — الرابط المباشر
--    (db.<ref>.supabase.co) بقى IPv6 بس ومش هيشتغل.
drop server if exists cloud cascade;
create server cloud
  foreign data wrapper postgres_fdw
  options (
    host    'aws-0-eu-west-1.pooler.supabase.com',
    port    '5432',
    dbname  'postgres',
    sslmode 'require'
  );

create user mapping for current_user
  server cloud
  options (
    user     'postgres.rxtjoqulmgkkcohmgzgi',
    password '<كلمة-سر-قاعدة-السحابة>'
  );

-- 3) الاختبار: نجيب صف واحد من السحابة
--    لو ظهر عدد الفروع = المسار شغّال ✅
--    لو خطأ اتصال/مهلة = خروج المنفذ 5432 مقفول على السيرفر ❌
create schema if not exists cloudsrc;
import foreign schema public
  limit to (branches)
  from server cloud into cloudsrc;

select 'الفروع من السحابة' as النتيجة, count(*) as العدد from cloudsrc.branches;
