-- migrate_81_region_below_min_fee.sql
-- رسم خدمة إضافي لكل منطقة يُقترح على التوزيع لو إجمالي الطلب أقل من الحد الأدنى
-- (min_order_amount). قيمة ثابتة، غير خدمة التوصيل (delivery_fee).
-- تنبيه فقط في شاشة التوزيع — الموزّع يضيفه يدويًا بزر «إضافة تحصيل».
-- يُطبَّق على القاعدتين: السحابة + السيرفر الذاتي.

alter table public.regions
  add column if not exists below_min_fee numeric not null default 0;

comment on column public.regions.below_min_fee is 'رسم خدمة إضافي يُقترح على التوزيع لو إجمالي الطلب أقل من min_order_amount (غير خدمة التوصيل)';
