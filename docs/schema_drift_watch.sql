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
--
--  ═══ 🔴 درس تالت — الحارس كان بيكذب من يوم ما اتعمل (2026-09-25) ═══
--
--  فلتر الاستثناءات كان مكتوب كده:
--      and not exists (select 1 from excl e where obj like e.obj || '%')
--
--  `obj` من غير اسم جدول. وبوستجرس بيربط الاسم بأقرب نطاق — وهو
--  `excl e` اللي جوّه الاستعلام الفرعي مش الجدول اللي برّه. يعني
--  اللي اتنفّذ فعليًا:  e.obj LIKE e.obj || '%'  → صح دايمًا →
--  `not exists` غلط دايمًا → **كل الصفوف بتتشال**.
--
--  النتيجة: `norm` بتطلع فاضية، والمقارنة بتقارن فاضي بفاضي، والخرج
--  «✓ مفيش انحراف». لمدة أسبوع، والسيرفر ناقصه ٧ جداول (منها
--  customers) و١٥ دالة و٧ تريجرات.
--
--  إصلاحان، والتاني أهم من الأول:
--    1. تسمية صريحة لكل عمود جاي من برّه (`c.obj`).
--    2. **أرضية تعقّل**: الحارس بيعدّ صفوف المصدر وصفوف ما بعد
--       الفلتر. لو الفلتر شال أكتر من 5% أو المصدر فاضي → بيوقف
--       بخطأ. عدّ من 1730 لصفر وقال «تمام» — ماكانش فيه حاجة تسأل.
--
--  القاعدة اللي خرجت من ده وبتنطبق على كل حارس عندنا:
--  **الفاضي مش نضيف.** أي فحص لازم يثبت إنه شاف داتا قبل ما يحكم.
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
  -- ⚠️ الاسم `c` مش تزويق: من غيره `obj` جوّه الاستعلام الفرعي
  --    بتتربط بـ excl.obj مش بالجدول ده، فالشرط يبقى
  --    e.obj LIKE e.obj||'%' = صح دايمًا، والفلتر يشيل كل الصفوف.
  --    دي الغلطة اللي خلّت الحارس يكذب من يوم ما اتعمل.
  select c.kind, c.obj,
         regexp_replace(regexp_replace(replace(c.ddl, 'public.', ''), '\s+', ' ', 'g'), ';\s*$', '')
  from cloudsrc.v_migration_ddl c
  where c.obj not in (select e.obj from excl e)
    and split_part(c.obj, ':', 1) not in (select e.obj from excl e)   -- الجرانت شكله table:role
    -- قيود وفهارس الجداول المستثناة اسمها بيبدأ باسم الجدول
    and not exists (select 1 from excl e where c.obj like e.obj || '%')
),
srv(kind, d) as (
  select kind,
         regexp_replace(regexp_replace(replace(ddl, 'public.', ''), '\s+', ' ', 'g'), ';\s*$', '')
  from public.v_migration_ddl
)
select c.kind, c.obj
from norm c
where not exists (select 1 from srv s where s.kind = c.kind and s.d = c.d);

-- نسخة من norm قبل المقارنة — الأرضية بتعدّ منها
create temp view drift_src as
with excl as (
  select unnest(array[
    'notify_fcm_on_assign','notify_on_driver_change','trg_delivery_perf',
    'trg_fail_perf','trg_trip_return_perf','sweep_unrated_perf',
    'pos_shifts_dupe_backup_20260905','wallet_done_backfill_20260910',
    'v_migration_ddl','v_migration_post'
  ]) as obj
)
select c.kind, c.obj
from cloudsrc.v_migration_ddl c
where c.obj not in (select e.obj from excl e)
  and split_part(c.obj, ':', 1) not in (select e.obj from excl e)
  and not exists (select 1 from excl e where c.obj like e.obj || '%');

-- ══ أرضية تعقّل — تتنفّذ قبل أي حكم ═════════════════════════════════
-- الحارس عدّ من 1730 صف لصفر وقال «تمام». ماكانش فيه حاجة تسأل
-- «معقول الفلتر يشيل كل حاجة؟». القاعدة دلوقتي: **الفاضي مش نضيف** —
-- الحارس لازم يثبت إنه شاف داتا قبل ما يحكم، وإلا يوقف بخطأ.
do $sane$
declare src int; kept int; loc int;
begin
  select count(*) into src  from cloudsrc.v_migration_ddl;
  select count(*) into loc  from public.v_migration_ddl;
  select count(*) into kept from drift_src;

  if src < 500 then
    raise exception 'مصدر السحابة رجّع % صف بس — الرابط مقطوع أو الفيو اتغيّر. مش هحكم على حاجة.', src;
  end if;
  if loc < 500 then
    raise exception 'الفيو المحلي رجّع % صف بس — مش هحكم على حاجة.', loc;
  end if;
  if kept < src * 0.90 then
    -- ملحوظة: %% في RAISE معناها علامة نسبة حرفية مش خانة، فبنتجنّبها
    raise exception 'الفلتر شال % من % صف — % بالمية. ده مش استثناءات، ده عطل في الفلتر.',
      src - kept, src, round((src - kept) * 100.0 / src);
  end if;
  raise notice 'الفحص بيقارن % صف من السحابة مقابل % على السيرفر.', kept, loc;
end $sane$;

\echo '════ حاجات موجودة على السحابة ومالهاش نظير على السيرفر ════'
select kind as "النوع", obj as "الاسم" from drift order by kind, obj;

\echo ''
select case when count(*) = 0 then '✓ مفيش انحراف — السيرفر مطابق للسحابة'
            else '⚠️ ' || count(*)::text || ' حاجة منحرفة — شوف القايمة فوق' end as "الخلاصة"
from drift;
