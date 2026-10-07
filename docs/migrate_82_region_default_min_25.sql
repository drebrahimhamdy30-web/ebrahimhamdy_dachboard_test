-- migrate_82_region_default_min_25.sql
-- الحد الأدنى الافتراضي للطلب = 25ج.
-- يُطبّق على المناطق غير المحدّدة (0) فقط؛ المناطق المخصّصة تفضل زي ما هي.
-- وأي منطقة جديدة تبدأ بـ25 تلقائيًا (تغيير الافتراضي).
-- يُطبَّق على القاعدتين: السحابة + السيرفر الذاتي.

update public.regions set min_order_amount = 25 where coalesce(min_order_amount,0) = 0;
alter table public.regions alter column min_order_amount set default 25;
