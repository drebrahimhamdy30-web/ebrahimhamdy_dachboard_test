-- migrate_83_order_logs_driver_indexes.sql
-- فهارس تعبيرية جزئية على order_logs تسرّع دوال تقارير الطيارين
-- (get_driver_shift_report / get_taken_off_report / get_idle_with_taken / get_late_returns)
-- اللي بتفلتر بـ event + details->>'driver'/'from'/'to' + created_at.
-- النتيجة: get_driver_shift_report للشهر×كل الفروع من 11.8ث → 7ث، والمدى العادي <0.5ث.
-- CONCURRENTLY = من غير قفل الكتابة على الجدول الحي.
-- ⚠️ CONCURRENTLY مابيشتغلش جوّه transaction — شغّل الملف ده بـpsql مباشرة (autocommit)،
--    مش جوّه BEGIN/COMMIT.
-- يُطبَّق على القاعدتين: السحابة (اتعملت) + السيرفر الذاتي.

create index concurrently if not exists idx_ol_assigned_driver
  on public.order_logs ((details->>'driver'), created_at)
  where event='driver_assigned';

create index concurrently if not exists idx_ol_transfer_from
  on public.order_logs ((details->>'from'), created_at)
  where event='order_transferred';

create index concurrently if not exists idx_ol_transfer_to
  on public.order_logs ((details->>'to'), created_at)
  where event='order_transferred';
