-- ═══════════════════════════════════════════════════════════════════
-- إعادة تعريف جداول cloudsrc الأجنبية + إرجاع حروف الفروع
-- ═══════════════════════════════════════════════════════════════════
-- (السيرفر الذاتي بس — السحابة مالهاش cloudsrc)
--
-- ═══ العيب: المزامنة بتمسح أي عمود الجدول الأجنبي ما يعرفوش ═══
--
-- اللي حصل بالتفصيل (2026-09-25):
--   ١) ترحيل 46 ضاف `branches.letter` وحدّده للأربع فروع.
--   ٢) اتأكدنا: `branch_letters()` رجّعت الأربعة صح، و
--      quick_search_stock رجّع مفتاح `f` للسيوف.
--   ٣) اتشغّلت `sync-from-cloud.sh`.
--   ٤) بعدها `letter` بتاع السيوف بقى **null** ومفتاح `f` اختفى
--      من نتيجة الدالة — من غير أي خطأ في أي مكان.
--
-- السبب: `cloudsrc.branches` **جدول أجنبي معرّف وقت الترحيل الأول**
--   ومش عارف عمود `letter`. والمزامنة بتحسب «الأعمدة المشتركة بين
--   الجهتين» وبتعمل **delete ثم insert** بالأعمدة المشتركة بس. فأي
--   عمود محلي مش في تعريف الجدول الأجنبي بيرجع لقيمته الافتراضية.
--
--   و`branch_letters()` بتفلتر `letter is not null`، فالسيوف اختفى
--   من كل دالة مبنية على الحروف — ومحدش كان هياخد باله غير لما يلاقي
--   عمود فرع ناقص من شاشة.
--
-- ⚠️ وليه السيوف بس وهو أربع فروع في نفس الجدول؟ النمط delta بيحذف
--    ويعيد إدخال **الصفوف اللي وقتها >= آخر 3 أيام** بس، وعمود وقت
--    `branches` هو `created_at`. السيوف لوحده اتعمل قريب، فهو الصف
--    الوحيد اللي اتحذف واترجع. يعني التلف **جزئي وبيعتمد على الصف** —
--    وده اللي خلاه يبان عشوائي: تلات فروع سليمين وواحد مكسور بالساكت.
--
-- ⚠️ ده **مش خاص بـletter**: أي عمود اتضاف بأي ترحيل لجدول بيتزامن
--    بيتمسح كل مزامنة لحد ما الجدول الأجنبي يتعرّف من جديد. عشان كده
--    الترحيل ده بيعيد تعريف **كل** جداول cloudsrc مش `branches` بس،
--    وفي آخره تقرير بيقيس لو فاضل أعمدة محلية مش موجودة على السحابة.
--
-- ⚠️ الجدول الأجنبي **لقطة**: كل ترحيل بيضيف عمود لجدول بيتزامن لازم
--    يعيد استيراده. راجع تحذير refresh_data_from_cloud.sql.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- معاملة واحدة: DDL في بوستجرس بيرجع لو حصل خطأ، فمستحيل نسيب
-- cloudsrc منهار والمزامنة واقفة.
begin;

-- بيانات الاتصال (server cloud + user mapping) مش بتتأثر — إحنا
-- بنعيد تعريف الجداول بس، فمفيش كلمة سر محتاجة هنا.
drop schema if exists cloudsrc cascade;
create schema cloudsrc;
import foreign schema public from server cloud into cloudsrc;

-- الحروف تترجع. مش `where letter is null` زي ترحيل 46: هنا إحنا
-- **بنصلّح** قيمة اتمسحت، فلازم نكتبها مهما كانت.
update public.branches set letter = 'm' where code = 'mamora';
update public.branches set letter = 's' where code = 'san';
update public.branches set letter = 'b' where code = 'bishr';
update public.branches set letter = 'f' where code = 'seyouf';

commit;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════
-- ١) الفحص: الحروف رجعت؟
-- ═══════════════════════════════════════════════════════════════════
select code, name, letter, is_active
  from public.branches order by coalesce(sort_order, 999), name;

-- ═══════════════════════════════════════════════════════════════════
-- ٢) الحروف وصلت للجدول الأجنبي كذلك؟ (لو لأ، المزامنة الجاية
--    هتمسحها تاني — وده الفحص اللي كان ناقص من الأول)
-- ═══════════════════════════════════════════════════════════════════
select 'cloudsrc.branches فيه letter'                     as الفحص,
       exists(select 1 from pg_attribute a
               where a.attrelid = 'cloudsrc.branches'::regclass
                 and a.attname = 'letter' and a.attnum > 0
                 and not a.attisdropped)::text            as النتيجة;

-- ═══════════════════════════════════════════════════════════════════
-- ٣) قياس باقي الخطر: أعمدة موجودة محليًا ومش موجودة على السحابة،
--    في جداول بتتزامن. كل عمود هنا **بيتمسح كل مزامنة**.
--    (أعمدة مولّدة مستثناة — المزامنة مابتكتبهاش أصلًا)
-- ═══════════════════════════════════════════════════════════════════
select c.relname                                    as الجدول,
       string_agg(a.attname, ', ' order by a.attnum) as أعمدة_بتتمسح_كل_مزامنة
  from pg_class c
  join pg_namespace n  on n.oid = c.relnamespace
  join pg_attribute a  on a.attrelid = c.oid and a.attnum > 0
                      and not a.attisdropped and a.attgenerated = ''
 where n.nspname = 'public' and c.relkind = 'r'
   and c.relname !~ '_backup_|_backfill_|_staging$'
   and exists (select 1 from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace
                where n2.nspname = 'cloudsrc' and c2.relname = c.relname)
   and not exists (select 1 from pg_attribute a2
                    where a2.attrelid = ('cloudsrc.' || quote_ident(c.relname))::regclass
                      and a2.attname = a.attname and a2.attnum > 0 and not a2.attisdropped)
 group by c.relname
 order by c.relname;
