-- ═══════════════════════════════════════════════════════════════════
-- «تتبع التحويلات» بقى لحظي: اللي قايم دلوقتي بس
-- ═══════════════════════════════════════════════════════════════════
-- migrate_58 عمل get_transfer_tracking(from,to) اللي بيرجّع أرشيف فترة.
-- المطلوب فعليًا أبسط: أفتح الشاشة أعرف **التحويلة الحالية** تمت ولا لأ
-- ومين طالع بيها — مش كل تحويلات الأسبوع. الأرشيف كان بيملا الشاشة بصفوف
-- خلصت ومحدش محتاجها.
--
-- get_open_transfers() مالهاش بارامترات وبترجّع اللقطة الحالية:
--   shipments = تحويلات لسه في الشارع (لسه ماطلعتش/مع الطيار) + اللي
--               وصلت النهاردة (عشان تتأكد إنها تمت) — ومعاها الطيار
--               وتليفونه وباقي طلبات رحلته.
--   requests  = طلبات التحويل اللي لسه pending (أي عمر) — دي «قايمة»
--               بطبيعتها لحد ما الفرع يردّ.
-- مفيش أي تخزين — دالة قراءة بتقرا orders/task/trips زي أي تقرير.
--
-- وبنشيل get_transfer_tracking لأن مفيش حاجة بتناديها بعد التعديل.
-- branch_from_text بتفضل (بتستنتج الفرع المستلم للصفوف القديمة).
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.get_transfer_tracking(date, date);

CREATE OR REPLACE FUNCTION public.get_open_transfers()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
WITH t AS (SELECT (now() AT TIME ZONE 'Africa/Cairo')::date AS d),
ship AS (
  SELECT o.id, o.bill_no, o.branch_id, o.customer_name, o.cust_region, o.notes,
         o.status, o.driver_id, o.source_data,
         (o.bill_date    AT TIME ZONE 'Africa/Cairo') AS created_c,
         (o.picked_at    AT TIME ZONE 'Africa/Cairo') AS picked_c,
         (o.delivered_at AT TIME ZONE 'Africa/Cairo') AS delivered_c,
         (o.status NOT IN ('completed','cancelled','failed'))       AS is_live
    FROM orders o CROSS JOIN t
   WHERE (o.bill_no LIKE 'TRF-%' OR o.staff_notes = '📌 تحويلة')
     -- لسه قايمة، أو خلصت النهاردة (عشان الشاشة تأكّد إنها تمت)
     AND ( o.status NOT IN ('completed','cancelled','failed')
        OR (o.delivered_at AT TIME ZONE 'Africa/Cairo')::date = t.d
        OR (o.bill_date    AT TIME ZONE 'Africa/Cairo')::date = t.d )
     -- حارس: طلب قديم فضل معلّق بالغلط مايعيشش في الشاشة للأبد
     AND (o.bill_date AT TIME ZONE 'Africa/Cairo')::date >= t.d - 7
),
sh AS (
  SELECT s.*,
         sb.name AS from_branch,
         nullif(s.source_data->>'to_branch','') AS to_exact,
         coalesce(nullif(s.source_data->>'to_branch',''),
                  public.branch_from_text(s.customer_name),
                  public.branch_from_text(s.cust_region)) AS to_branch,
         s.source_data->>'added_by' AS created_by,
         tr.id AS trip_id, tr.status AS trip_status,
         d.full_name AS driver_name, d.phone AS driver_phone
    FROM ship s
    LEFT JOIN branches sb ON sb.id = s.branch_id
    LEFT JOIN LATERAL (
      SELECT t2.id, t2.status, t2.driver_id
        FROM trip_orders tox JOIN trips t2 ON t2.id = tox.trip_id
       WHERE tox.order_id = s.id
       ORDER BY t2.created_at DESC LIMIT 1
    ) tr ON true
    LEFT JOIN drivers d ON d.id = coalesce(tr.driver_id, s.driver_id)
),
req AS (
  SELECT q.id, q."user" AS req_user, q.branch AS from_branch,
         q.item_code, q.item_name, q.qty, q.cust_name, q.note,
         (q.created_at AT TIME ZONE 'Africa/Cairo') AS created_c,
         round(extract(epoch FROM (now() - q.created_at)) / 60)::int AS age_min,
         u.branch AS req_branch, u.full_name AS req_name
    FROM task q
    LEFT JOIN LATERAL (
      SELECT bu.branch, bu.full_name FROM branch_users bu
       WHERE bu.username = q."user" OR bu.mobile = q."user"
       ORDER BY bu.is_active DESC NULLS LAST LIMIT 1
    ) u ON true
   WHERE q.type = 'تحويل'
     AND coalesce(nullif(btrim(coalesce(q.state,'')),''),'pending') = 'pending'
)
SELECT jsonb_build_object(
  'now', to_char(now() AT TIME ZONE 'Africa/Cairo','HH24:MI'),
  'shipments', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', sh.id, 'bill_no', sh.bill_no, 'live', sh.is_live,
             'from_branch', sh.from_branch, 'to_branch', sh.to_branch,
             'to_exact', sh.to_exact IS NOT NULL,
             'to_hint', sh.customer_name, 'region', sh.cust_region,
             'created_by', sh.created_by, 'notes', sh.notes, 'status', sh.status,
             'created',   to_char(sh.created_c,   'HH24:MI'),
             'created_d', to_char(sh.created_c,   'YYYY-MM-DD'),
             'picked',    to_char(sh.picked_c,    'HH24:MI'),
             'delivered', to_char(sh.delivered_c, 'HH24:MI'),
             'age_min',   round(extract(epoch FROM (now() - (sh.created_c AT TIME ZONE 'Africa/Cairo')))/60)::int,
             'driver_name', sh.driver_name, 'driver_phone', sh.driver_phone,
             'others', coalesce((
                SELECT jsonb_agg(jsonb_build_object(
                         'bill_no', o2.bill_no, 'name', o2.customer_name,
                         'region', o2.cust_region, 'status', o2.status) ORDER BY o2.bill_no)
                  FROM trip_orders t3 JOIN orders o2 ON o2.id = t3.order_id
                 WHERE t3.trip_id = sh.trip_id AND t3.order_id <> sh.id
                   AND o2.status NOT IN ('cancelled')), '[]'::jsonb)
           ) ORDER BY sh.is_live DESC, sh.created_c DESC)
      FROM sh), '[]'::jsonb),
  'requests', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', req.id, 'from_branch', req.from_branch,
             'req_branch', coalesce(req.req_branch, req.req_user),
             'req_name', coalesce(req.req_name, req.req_user),
             'item_code', req.item_code, 'item_name', req.item_name,
             'qty', req.qty, 'cust_name', req.cust_name, 'note', req.note,
             'created',   to_char(req.created_c, 'HH24:MI'),
             'created_d', to_char(req.created_c, 'YYYY-MM-DD'),
             'age_min', req.age_min
           ) ORDER BY req.created_c DESC)
      FROM req), '[]'::jsonb)
);
$fn$;

COMMENT ON FUNCTION public.get_open_transfers() IS
  'لقطة لحظية: التحويلات اللي لسه في الشارع + اللي وصلت النهاردة + طلبات التحويل المعلّقة';

GRANT EXECUTE ON FUNCTION public.get_open_transfers() TO anon, authenticated;

COMMIT;
