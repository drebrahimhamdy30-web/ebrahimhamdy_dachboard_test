-- ═══════════════════════════════════════════════════════════════════
-- تفاصيل رحلة واحدة — «إيه اللي حصل في الرحلة بالظبط»
-- ═══════════════════════════════════════════════════════════════════
-- تنبيه «العودة المتأخرة» في تقارير الطيارين كان بيوسّع خط زمني مختصر
-- (استلام ← تسليم ← رجوع) من غير أسماء عملاء ولا عناوين ولا أوقات
-- إنشاء الطلبات — فمش بتعرف التأخير جه منين.
--
-- الدالة دي بترجّع الرحلة + كل طلباتها بتوقيتاتها الكاملة في نداء واحد
-- (jsonb، صف واحد) عشان الكارت المنبثق يعرضها من غير ما يخرج من الشاشة.
--   • وقت إنشاء الطلب (والتفعيل لو الطلب اتعمله تنشيط بعدين)
--   • وقت تعيين الطيار · وقت استلام الطيار · وقت التسليم
--   • اسم العميل وعنوانه ومنطقته وقيمته وحالته وتقييمه
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.get_trip_details(p_trip_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT jsonb_build_object(
    'trip', (
      SELECT jsonb_build_object(
        'id', t.id, 'trip_number', t.trip_number, 'driver_name', t.driver_name,
        'branch', b.name, 'status', t.status, 'orders_count', t.orders_count,
        'created_at', t.created_at, 'started_at', t.started_at, 'completed_at', t.completed_at,
        'return_expected_minutes', t.return_expected_minutes,
        'return_actual_minutes', t.return_actual_minutes,
        'return_distance_meters', t.return_distance_meters,
        'return_rating', t.return_rating)
        FROM trips t LEFT JOIN branches b ON b.id = t.branch_id
       WHERE t.id = p_trip_id),
    'orders', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', o.id, 'bill_no', o.bill_no,
               'customer_name', o.customer_name, 'customer_address', o.customer_address,
               'cust_region', o.cust_region, 'cust_code', o.cust_code,
               'total_bill_net', o.total_bill_net, 'status', o.status,
               'created_at', o.created_at, 'last_activated_at', o.last_activated_at,
               'assigned_at', o.assigned_at, 'picked_at', o.picked_at, 'delivered_at', o.delivered_at,
               'perf_rating', o.perf_rating, 'sla_rating', o.sla_rating,
               'sla_minutes', o.sla_minutes, 'sla_actual_minutes', o.sla_actual_minutes)
             ORDER BY coalesce(o.delivered_at, o.picked_at, o.created_at))
        FROM trip_orders tr JOIN orders o ON o.id = tr.order_id
       WHERE tr.trip_id = p_trip_id), '[]'::jsonb)
  );
$fn$;

GRANT EXECUTE ON FUNCTION public.get_trip_details(uuid) TO anon, authenticated;

COMMIT;
