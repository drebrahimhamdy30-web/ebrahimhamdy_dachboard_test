-- ═══════════════════════════════════════════════════════════════════
-- خطوة 0-ب: إصلاح المصادقة
-- ═══════════════════════════════════════════════════════════════════
-- ✅ الشبكة اتأكدت: السيرفر وصل لـ 108.128.216.176:5432 ورجعله رد من
--    Postgres. المنفذ مفتوح والمبرمج مش محتاج.
--
-- ❌ اللي فشل: المصادقة. الرسالة قالت user "postgres" مش
--    "postgres.rxtjoqulmgkkcohmgzgi" — يعني الـuser mapping مااتقراش،
--    فـpostgres_fdw رجع لاسم المستخدم الحالي. والـpooler لازم ياخد اسم
--    المشروع في اسم المستخدم عشان يعرف يوصّلك للقاعدة الصح.
--
-- السبب الغالب: `for current_user` بيربط الخريطة بدور معيّن، والاستعلام
-- اتنفّذ بدور تاني. بنعملها `for public` عشان تشتغل مع أي دور.
--
-- ⚠️ غيّر <كلمة-السر> في **المكانين** تحت (بنفس القيمة).
-- ═══════════════════════════════════════════════════════════════════

-- ── 1) مين إحنا أصلًا؟ (للتشخيص) ──────────────────────────────────
select current_user as الدور_الحالي, session_user as دور_الجلسة;

-- ── 2) اختبار مباشر بتجاوز الخريطة تمامًا ────────────────────────
--    بنبعت بيانات الدخول صريحة. لو ده نجح = الباسورد صح والمشكلة كانت
--    في الخريطة بس. لو فشل = الباسورد نفسه غلط.
create extension if not exists dblink;

select 'اختبار مباشر' as النوع, *
from dblink(
  'host=aws-0-eu-west-1.pooler.supabase.com port=5432 dbname=postgres '
  || 'user=postgres.rxtjoqulmgkkcohmgzgi password=<كلمة-السر> sslmode=require',
  'select count(*) from public.branches'
) as t(عدد_الفروع bigint);

-- ── 3) لو اللي فوق نجح، شغّل ده: خريطة لكل الأدوار ───────────────
create extension if not exists postgres_fdw;

drop server if exists cloud cascade;
create server cloud
  foreign data wrapper postgres_fdw
  options (
    host    'aws-0-eu-west-1.pooler.supabase.com',
    port    '5432',
    dbname  'postgres',
    sslmode 'require'
  );

-- ⚠️ `for public` مش `for current_user` — دي كانت المشكلة
create user mapping for public
  server cloud
  options (
    user     'postgres.rxtjoqulmgkkcohmgzgi',
    password '<كلمة-السر>'
  );

-- وخريطة صريحة لـpostgres كمان، للأمان
drop user mapping if exists for postgres server cloud;
create user mapping for postgres
  server cloud
  options (
    user     'postgres.rxtjoqulmgkkcohmgzgi',
    password '<كلمة-السر>'
  );

-- ── 4) التأكيد النهائي ───────────────────────────────────────────
drop schema if exists cloudsrc cascade;
create schema cloudsrc;
import foreign schema public limit to (branches) from server cloud into cloudsrc;

select 'عبر FDW' as النوع, count(*) as عدد_الفروع from cloudsrc.branches;
