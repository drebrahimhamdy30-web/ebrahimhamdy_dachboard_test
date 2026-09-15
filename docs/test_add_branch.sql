-- ═══════════════════════════════════════════════════════════════════
--  اختبار: إضافة فرع جديد تظبط نفسها لوحدها؟
-- ═══════════════════════════════════════════════════════════════════
--  ده الهدف الأصلي من الشكل الطولي. المقارنة اللي عدّت (صفر فروق)
--  أثبتت إن الأنبوبة بتطلّع نفس أرقام الإنتاج — بس ما جرّبتش الحاجة
--  اللي عملنا الشغل ده عشانها أصلًا.
--
--  ⚠️ الاختبار كله جوّه transaction بتترجع في الآخر.
--     DDL في بوستجرس بيترجع كمان (مش زي MySQL) — يعني الأقسام
--     والأعمدة اللي هتتعمل هتتلغي لوحدها. مافيش أثر باقي.
--
--  يتشغّل على السيرفر.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- فرع وهمي بكود مالوش جدول stock_ قديم — زي الفرع الجديد بالظبط
insert into public.branches (name, code, is_active, sort_order)
values ('فرع اختبار مؤقت', 'zztest', true, 99);

select public.ensure_branch_partitions() as ناتج_الأقسام;
select public.sync_stock_flat_columns()  as ناتج_الأعمدة;

-- (١) الأقسام اتعملت؟
select 'أقسام الفرع الجديد' as الفحص,
       count(*) as اتعمل,
       2 as المتوقع,
       case when count(*) = 2 then '✅' else '⛔' end as النتيجة
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('branch_stock_zztest','branch_stock_stage_zztest');

-- (٢) أعمدة الظل اتضافت؟
select 'أعمدة stock_flat_shadow' as الفحص,
       count(*) as اتضاف,
       3 as المتوقع,
       case when count(*) = 3 then '✅' else '⛔' end as النتيجة
from information_schema.columns
where table_schema='public' and table_name='stock_flat_shadow'
  and column_name in ('zztest_h','zztest_q','zztest_p');

-- (٣) الأهم: السحب مابيقعش على فرع مالوش بيانات قديمة
select 'السحب مع فرع بلا مصدر' as الفحص,
       (public.sync_branch_stock_from_legacy() ? 'zztest') as ضمّه,
       'false متوقّعة — بيتخطّاه بهدوء' as المتوقع;

rollback;

-- بعد الترجيع: لازم مايفضلش أي أثر
select 'أثر باقي بعد الترجيع' as الفحص,
       (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relname like '%zztest%')
     + (select count(*) from information_schema.columns
         where table_schema='public' and column_name like 'zztest%')
     + (select count(*) from public.branches where code='zztest') as المتبقي,
       0 as المتوقع;
