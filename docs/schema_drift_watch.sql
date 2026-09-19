-- ═══════════════════════════════════════════════════════════════════
--  حارس الانحراف: أي تعديل على السحابة مش موجود على السيرفر
-- ═══════════════════════════════════════════════════════════════════
--  ليه: اكتشفنا 17 دالة منحرفة **بالصدفة** — المالك فتح شاشة مؤشر
--  الأداء ولقى جزء خدمة العملاء فاضي. لولا كده كنا هنحوّل على سيرفر
--  فيه دوال قديمة ومحدش واخد باله.
--
--  بيقارن v_migration_ddl في الجهتين: جداول وأعمدة وفهارس وقيود ودوال
--  وتريجرات وسياسات وصلاحيات — كلها بصيغة واحدة. بيطلّع الفرق بس.
--
--  ═══ درسان من أول تشغيل (طلّع 553 إنذار كلها كذب) ═══
--
--  1. **الربط بالاسم مابينفعش.** اسم السياسة متكرر على جداول كتير
--     (p_all على عشرين جدول)، فالربط بـ(النوع، الاسم) بيضرب كل واحدة
--     في التانية ويطلّع 207 فرق والبرودكشن كله فيه 122 سياسة.
--     الحل: نقارن **النصوص كمجموعات** — كل نص في السحابة له نظير
--     مطابق على السيرفر ولا لأ، بغضّ النظر عن الاسم.
--
--  2. **نفس الشيء ممكن يتكتب بشكلين.** بوستجرس بيكتب
--     REFERENCES public.stores أو REFERENCES stores حسب search_path
--     بتاع الجلسة. ده خلّى 46 مفتاح أجنبي و48 تريجر يبانوا مختلفين
--     وهم حرف بحرف نفس الحاجة. الحل: نوحّد الصياغة قبل المقارنة.
--
--  ⚠️ حارس بيكذب أسوأ من إنه مايكونش موجود — بعد أسبوع حد هيبطّل
--     يبصّله. فأي إنذار هنا لازم يكون حقيقي.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'cloudsrc' and c.relname = 'v_migration_ddl') then
    execute 'import foreign schema public limit to (v_migration_ddl) from server cloud into cloudsrc';
  end if;
end $$;

create temp view drift as
with excl as (
  select unnest(array[
    -- 🔒 دوال معدّلة على السيرفر عن قصد (عزل الإشعارات وتقييم الأداء).
    --    فك العزل يوم التحويل بس — قبله أي تجربة هتبعت إشعار لطيار حقيقي.
    'notify_fcm_on_assign','notify_on_driver_change','trg_delivery_perf',
    'trg_fail_perf','trg_trip_return_perf','sweep_unrated_perf',
    -- جداول نسخ مؤقتة من إصلاحات قديمة — مالهاش لازمة على السيرفر
    'pos_shifts_dupe_backup_20260905','wallet_done_backfill_20260910',
    -- أدوات الترحيل نفسها
    'v_migration_ddl','v_migration_post'
  ]) as obj
),
-- توحيد الصياغة: اسم السكيما، والمسافات المتكررة، وآخر فاصلة منقوطة
norm(kind, obj, d) as (
  select kind, obj,
         regexp_replace(regexp_replace(replace(ddl, 'public.', ''), '\s+', ' ', 'g'), ';\s*$', '')
  from cloudsrc.v_migration_ddl
  where obj not in (select obj from excl)
    and split_part(obj, ':', 1) not in (select obj from excl)   -- الجرانت شكله table:role
    -- قيود وفهارس الجداول المستثناة اسمها بيبدأ باسم الجدول
    and not exists (select 1 from excl e where obj like e.obj || '%')
),
srv(kind, d) as (
  select kind,
         regexp_replace(regexp_replace(replace(ddl, 'public.', ''), '\s+', ' ', 'g'), ';\s*$', '')
  from public.v_migration_ddl
)
select c.kind, c.obj
from norm c
where not exists (select 1 from srv s where s.kind = c.kind and s.d = c.d);

\echo '════ حاجات موجودة على السحابة ومالهاش نظير على السيرفر ════'
select kind as "النوع", obj as "الاسم" from drift order by kind, obj;

\echo ''
select case when count(*) = 0 then '✓ مفيش انحراف — السيرفر مطابق للسحابة'
            else '⚠️ ' || count(*)::text || ' حاجة منحرفة — شوف القايمة فوق' end as "الخلاصة"
from drift;
