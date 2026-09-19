-- ═══════════════════════════════════════════════════════════════════
--  حارس الانحراف: أي تعديل على السحابة مش موجود على السيرفر
-- ═══════════════════════════════════════════════════════════════════
--  ليه: اكتشفنا 17 دالة منحرفة **بالصدفة** — لأن المالك فتح شاشة
--  مؤشر الأداء ولقى جزء فاضي. لو ماكانش فتحها، كنا هنحوّل على سيرفر
--  فيه دوال قديمة ومحدش واخد باله.
--
--  ده بيقارن v_migration_ddl في الجهتين — بيغطّي الجداول والأعمدة
--  والفهارس والقيود والدوال والتريجرات والسياسات والصلاحيات كلها
--  بصيغة واحدة، وبيطلّع الفرق بس.
--
--  بيشتغل كل يوم مع المزامنة. ساكت لو مفيش انحراف.
--
--  ⚠️ المستثنى مقصود — اقرا السبب قبل ما تشيل أي سطر من القايمة.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- الـview بتاع السحابة (لو مش متقاسم لسه)
do $$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='cloudsrc' and c.relname='v_migration_ddl') then
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
)
select c.kind, c.obj,
       case when s.obj is null then 'ناقص على السيرفر' else 'مختلف' end as حالة
from cloudsrc.v_migration_ddl c
left join public.v_migration_ddl s on s.kind = c.kind and s.obj = c.obj
where c.obj not in (select obj from excl)
  and split_part(c.obj, ':', 1) not in (select obj from excl)   -- الجرانت شكله table:role
  and (s.obj is null or md5(s.ddl) <> md5(c.ddl));

\echo '════ انحراف عن السحابة ════'
select kind as "النوع", obj as "الاسم", حالة as "الحالة"
from drift order by kind, obj;

\echo ''
select case when count(*) = 0 then '✓ مفيش انحراف — السيرفر مطابق للسحابة'
            else '⚠️ ' || count(*)::text || ' حاجة منحرفة — شوف القايمة فوق' end as "الخلاصة"
from drift;
