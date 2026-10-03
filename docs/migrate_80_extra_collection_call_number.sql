-- migrate_80_extra_collection_call_number.sql
-- تحصيل إضافي يتحصّله الطيار فوق قيمة الفاتورة (مديونية سابقة/رسوم توصيل)
-- + رقم بديل للاتصال يبعته التوزيع للطيار (يظهر كزر اتصال في كارت الطلب).
-- يُطبَّق على القاعدتين: السحابة + السيرفر الذاتي.

alter table public.orders
  add column if not exists extra_collection numeric not null default 0,
  add column if not exists extra_collection_note text,
  add column if not exists driver_call_number text;

comment on column public.orders.extra_collection is 'مبلغ تحصيل إضافي يضاف على إجمالي الطلب وقت التسليم (يحدده التوزيع)';
comment on column public.orders.extra_collection_note is 'سبب/ملاحظة التحصيل الإضافي — تظهر للطيار';
comment on column public.orders.driver_call_number is 'رقم بديل يبعته التوزيع للطيار ليتصل به (يظهر كزر اتصال في كارت الطلب)';
