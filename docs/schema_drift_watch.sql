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

-- ── أعمدة الجهتين — للمقارنة بالكتالوج مش بنص الـDDL ─────────────
-- ⚠️ ليه: نص `create table` بيرتّب الأعمدة بأرقامها، وبوستجرس بيسيب
--    فجوة في الترقيم لما عمود يتشال. السحابة اتشال منها أعمدة على
--    مدى سنة، فـorders هيفضل «منحرف» للأبد وهو مطابق حرف بحرف.
--    وحارس معاه ضوضاء دايمة = حارس محدش بيبصّله بعد أسبوعين.
drop table if exists _cc_drift;
create temp table _cc_drift as
select * from dblink('cloud', $q$
  select c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
         a.attnotnull, pg_get_expr(ad.adbin, ad.adrelid)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
  where n.nspname = 'public' and c.relkind in ('r','p')
$q$) as t(tbl text, col text, typ text, nn boolean, dflt text);

drop table if exists _lc_drift;
create temp table _lc_drift as
select c.relname as tbl, a.attname as col,
       format_type(a.atttypid, a.atttypmod) as typ,
       a.attnotnull as nn, pg_get_expr(ad.adbin, ad.adrelid) as dflt
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
where n.nspname = 'public' and c.relkind in ('r','p');

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
    'v_migration_ddl','v_migration_post',
    -- نسخ وstaging مؤقتة — مقصود إنها مش على السيرفر. الانحراف
    -- المقصود بيخلّي العدّاد مش معبّر، فبنستثنيها.
    'sip_code_backup_20260922','sip_namefill_staging'
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
    and c.kind <> 'table'   -- الجداول بتتقارن بالكتالوج، مش بنص الـDDL
    -- جداول staging بتتعمل وتتمسح مع كل دورة مزامنة مخزون، فبتظهر
    -- وتختفي من القايمة حسب توقيت التشغيل. وجودها مش انحراف.
    and c.obj not like '%\_staging%'
),
srv(kind, d) as (
  select kind,
         regexp_replace(regexp_replace(replace(ddl, 'public.', ''), '\s+', ' ', 'g'), ';\s*$', '')
  from public.v_migration_ddl
)
select c.kind, c.obj
from norm c
where not exists (select 1 from srv s where s.kind = c.kind and s.d = c.d)
union all
-- جدول مش موجود خالص على السيرفر
select 'جدول'::text, c.tbl
from (select distinct tbl from _cc_drift) c
where not exists (select 1 from _lc_drift l where l.tbl = c.tbl)
  and c.tbl not in (select e.obj from excl e)
  and c.tbl not like '%\_staging%'
union all
-- عمود مختلف في جدول موجود في الجهتين (ناقص · نوع · not null · افتراضي)
select 'عمود'::text, coalesce(c.tbl, l.tbl) || '.' || coalesce(c.col, l.col)
from _cc_drift c
full join _lc_drift l on l.tbl = c.tbl and l.col = c.col
where exists (select 1 from _lc_drift x where x.tbl = coalesce(c.tbl, l.tbl))
  and exists (select 1 from _cc_drift y where y.tbl = coalesce(c.tbl, l.tbl))
  and coalesce(c.tbl, l.tbl) not in (select e.obj from excl e)
  and coalesce(c.tbl, l.tbl) not like '%\_staging%'
  and (c.col is null or l.col is null
       or c.typ  is distinct from l.typ
       or c.nn   is distinct from l.nn
       or c.dflt is distinct from l.dflt);

-- نسخة من norm قبل المقارنة — الأرضية بتعدّ منها
create temp view drift_src as
with excl as (
  select unnest(array[
    'notify_fcm_on_assign','notify_on_driver_change','trg_delivery_perf',
    'trg_fail_perf','trg_trip_return_perf','sweep_unrated_perf',
    'pos_shifts_dupe_backup_20260905','wallet_done_backfill_20260910',
    'v_migration_ddl','v_migration_post',
    -- نسخ وstaging مؤقتة — مقصود إنها مش على السيرفر. الانحراف
    -- المقصود بيخلّي العدّاد مش معبّر، فبنستثنيها.
    'sip_code_backup_20260922','sip_namefill_staging'
  ]) as obj
)
select c.kind, c.obj
from cloudsrc.v_migration_ddl c
where c.obj not in (select e.obj from excl e)
  and split_part(c.obj, ':', 1) not in (select e.obj from excl e)
  and not exists (select 1 from excl e where c.obj like e.obj || '%')
    -- جداول staging بتتعمل وتتمسح مع كل دورة مزامنة مخزون، فبتظهر
    -- وتختفي من القايمة حسب توقيت التشغيل. وجودها مش انحراف.
    and c.obj not like '%\_staging%'
  and c.kind <> 'table';

-- ══ أرضية تعقّل — تتنفّذ قبل أي حكم ═════════════════════════════════
-- الحارس عدّ من 1730 صف لصفر وقال «تمام». ماكانش فيه حاجة تسأل
-- «معقول الفلتر يشيل كل حاجة؟». القاعدة دلوقتي: **الفاضي مش نضيف** —
-- الحارس لازم يثبت إنه شاف داتا قبل ما يحكم، وإلا يوقف بخطأ.
do $sane$
declare src int; kept int; loc int;
begin
  select count(*) into src  from cloudsrc.v_migration_ddl where kind <> 'table';
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
