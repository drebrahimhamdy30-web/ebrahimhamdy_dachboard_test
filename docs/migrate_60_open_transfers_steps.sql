-- ═══════════════════════════════════════════════════════════════════
-- تتبع التحويلات: مراحل التحويلة (إنشاء ← إسناد ← استلام) والجاري فقط
-- ═══════════════════════════════════════════════════════════════════
-- تعديلان على get_open_transfers():
--   ١) الدالة بقت ترجّع **الجاري فقط** — التحويلات اللي اتسلّمت خلاص
--      اتشالت من الناتج (الفرع بيفتح الشاشة يسأل عن تحويلة شغّالة، مش
--      يتفرّج على اللي خلص).
--   ٢) ضفنا توقيت كل مرحلة عشان الكارت يعرض خط زمني واضح:
--        تم الإنشاء    ← bill_date + من أنشأها
--        تم الإسناد     ← assigned_at، وإن كان فاضي فوقت إضافتها للرحلة
--        تم الاستلام    ← picked_at
--      وكمان بيانات الرحلة والطيار وباقي طلبات نفس الرحلة.
--
-- مفيش أي تخزين — دالة قراءة على orders/task/trips زي أي تقرير.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.get_open_transfers()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
WITH t AS (SELECT (now() AT TIME ZONE 'Africa/Cairo')::date AS d),
ship AS (
  SELECT o.id, o.bill_no, o.branch_id, o.customer_name, o.cust_region, o.notes,
         o.status, o.driver_id, o.source_data,
         (o.bill_date   AT TIME ZONE 'Africa/Cairo') AS created_c,
         (o.assigned_at AT TIME ZONE 'Africa/Cairo') AS assigned_c,
         (o.picked_at   AT TIME ZONE 'Africa/Cairo') AS picked_c
    FROM orders o CROSS JOIN t
   WHERE (o.bill_no LIKE 'TRF-%' OR o.staff_notes = '📌 تحويلة')
     AND o.status NOT IN ('completed','cancelled','failed')   -- الجاري فقط
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
         tr.trip_id,
         (tr.added_at AT TIME ZONE 'Africa/Cairo') AS added_c,
         d.full_name AS driver_name, d.phone AS driver_phone
    FROM ship s
    LEFT JOIN branches sb ON sb.id = s.branch_id
    LEFT JOIN LATERAL (
      SELECT t2.id AS trip_id, t2.driver_id, tox.created_at AS added_at
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
  'now',   to_char(now() AT TIME ZONE 'Africa/Cairo','HH24:MI'),
  'today', (SELECT d FROM t),
  'shipments', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', sh.id, 'bill_no', sh.bill_no, 'status', sh.status,
             'from_branch', sh.from_branch, 'to_branch', sh.to_branch,
             'to_exact', sh.to_exact IS NOT NULL,
             'to_hint', sh.customer_name, 'region', sh.cust_region,
             'created_by', sh.created_by, 'notes', sh.notes,
             'created',    to_char(sh.created_c, 'HH24:MI'),
             'created_d',  to_char(sh.created_c, 'YYYY-MM-DD'),
             -- وقت الإسناد: من الطلب، وإلا وقت إضافته للرحلة
             'assigned',   to_char(coalesce(sh.assigned_c, sh.added_c), 'HH24:MI'),
             'assigned_d', to_char(coalesce(sh.assigned_c, sh.added_c), 'YYYY-MM-DD'),
             'picked',     to_char(sh.picked_c, 'HH24:MI'),
             'picked_d',   to_char(sh.picked_c, 'YYYY-MM-DD'),
             'in_trip',    sh.trip_id IS NOT NULL,
             'age_min',    round(extract(epoch FROM (now() - (sh.created_c AT TIME ZONE 'Africa/Cairo')))/60)::int,
             'driver_name', sh.driver_name, 'driver_phone', sh.driver_phone,
             'others', coalesce((
                SELECT jsonb_agg(jsonb_build_object(
                         'bill_no', o2.bill_no, 'name', o2.customer_name,
                         'region', o2.cust_region, 'status', o2.status) ORDER BY o2.bill_no)
                  FROM trip_orders t3 JOIN orders o2 ON o2.id = t3.order_id
                 WHERE t3.trip_id = sh.trip_id AND t3.order_id <> sh.id
                   AND o2.status NOT IN ('cancelled')), '[]'::jsonb)
           ) ORDER BY sh.created_c DESC)
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
  'تتبع التحويلات: التحويلات الجارية بمراحلها (إنشاء/إسناد/استلام) + الأصناف المطلوبة التي لم تُحوَّل بعد';

GRANT EXECUTE ON FUNCTION public.get_open_transfers() TO anon, authenticated;

COMMIT;
