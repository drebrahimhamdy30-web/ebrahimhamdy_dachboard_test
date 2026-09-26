-- ═══════════════════════════════════════════════════════════════════
-- تتبع التحويلات: كروت فقط — التحويلة بمراحلها + عدّادين لكل فرع
-- ═══════════════════════════════════════════════════════════════════
-- المطلوب من المالك بالنص: الشاشة كلها كروت. كل تحويلة من أي فرع في
-- كارت لوحدها بكل تفاصيلها (الإنشاء ← التعيين على طيار ← الاستلام ←
-- الوصول بالتاريخ والوقت)، وتحتها **عدد** الأصناف اللي الفرع طالبها
-- ولم تُحوَّل، وعدد الأصناف المطلوبة منه ولم يحوّلها. مافيش جداول ولا
-- فلاتر ولا أي حاجة تانية.
--
-- التغييرات عن migrate_60:
--   • الناتج بقى يشمل كمان تحويلات النهاردة اللي **وصلت** — عشان خطوة
--     «وصل» يكون ليها معنى ويعرف إنها تمت. (الجارية من آخر ٧ أيام
--     بتفضل ظاهرة لحد ما تخلص.)
--   • بدل مصفوفة طلبات الأصناف كاملة، بنرجّع **عدّادين لكل فرع** بس:
--       requested = الفرع ده طلبها من غيره ولسه ما اتحوّلتش
--       required  = مطلوبة من الفرع ده ولسه ما حوّلهاش
--     أخفّ على الشبكة، والشاشة مش محتاجة التفاصيل.
--
-- مفيش أي تخزين — دالة قراءة على orders/task/trips.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.get_open_transfers()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
WITH t AS (SELECT (now() AT TIME ZONE 'Africa/Cairo')::date AS d),
ship AS (
  SELECT o.id, o.bill_no, o.branch_id, o.customer_name, o.cust_region, o.notes,
         o.status, o.driver_id, o.source_data,
         (o.bill_date    AT TIME ZONE 'Africa/Cairo') AS created_c,
         (o.assigned_at  AT TIME ZONE 'Africa/Cairo') AS assigned_c,
         (o.picked_at    AT TIME ZONE 'Africa/Cairo') AS picked_c,
         (o.delivered_at AT TIME ZONE 'Africa/Cairo') AS delivered_c,
         (o.status NOT IN ('completed','cancelled','failed')) AS is_live
    FROM orders o CROSS JOIN t
   WHERE (o.bill_no LIKE 'TRF-%' OR o.staff_notes = '📌 تحويلة')
     AND ( o.status NOT IN ('completed','cancelled','failed')          -- جارية
        OR (o.delivered_at AT TIME ZONE 'Africa/Cairo')::date = t.d    -- وصلت النهاردة
        OR (o.bill_date    AT TIME ZONE 'Africa/Cairo')::date = t.d )  -- اتعملت النهاردة
     -- حارس: تحويلة قديمة فضلت معلّقة بالغلط ماتعيشش في الشاشة للأبد
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
-- طلبات الأصناف المعلّقة → عدّادين لكل فرع
pend AS (
  SELECT public.branch_from_text(q.branch) AS from_b,
         public.branch_from_text(coalesce(u.branch, q."user")) AS req_b
    FROM task q
    LEFT JOIN LATERAL (
      SELECT bu.branch FROM branch_users bu
       WHERE bu.username = q."user" OR bu.mobile = q."user"
       ORDER BY bu.is_active DESC NULLS LAST LIMIT 1
    ) u ON true
   WHERE q.type = 'تحويل'
     AND coalesce(nullif(btrim(coalesce(q.state,'')),''),'pending') = 'pending'
),
by_branch AS (
  SELECT b.name,
         count(*) FILTER (WHERE p.req_b  = b.name) AS requested,  -- طلبها الفرع
         count(*) FILTER (WHERE p.from_b = b.name) AS required     -- مطلوبة منه
    FROM branches b
    LEFT JOIN pend p ON (p.req_b = b.name OR p.from_b = b.name)
   GROUP BY b.name
)
SELECT jsonb_build_object(
  'now',   to_char(now() AT TIME ZONE 'Africa/Cairo','HH24:MI'),
  'today', (SELECT d FROM t),
  'pending', coalesce((
    SELECT jsonb_object_agg(name, jsonb_build_object('requested', requested, 'required', required))
      FROM by_branch), '{}'::jsonb),
  'shipments', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', sh.id, 'bill_no', sh.bill_no, 'status', sh.status, 'live', sh.is_live,
             'from_branch', sh.from_branch, 'to_branch', sh.to_branch,
             'to_exact', sh.to_exact IS NOT NULL,
             'to_hint', sh.customer_name, 'region', sh.cust_region,
             'created_by', sh.created_by, 'notes', sh.notes,
             'created',     to_char(sh.created_c,   'HH24:MI'),
             'created_d',   to_char(sh.created_c,   'YYYY-MM-DD'),
             'assigned',    to_char(coalesce(sh.assigned_c, sh.added_c), 'HH24:MI'),
             'assigned_d',  to_char(coalesce(sh.assigned_c, sh.added_c), 'YYYY-MM-DD'),
             'picked',      to_char(sh.picked_c,    'HH24:MI'),
             'picked_d',    to_char(sh.picked_c,    'YYYY-MM-DD'),
             'delivered',   to_char(sh.delivered_c, 'HH24:MI'),
             'delivered_d', to_char(sh.delivered_c, 'YYYY-MM-DD'),
             'in_trip',     sh.trip_id IS NOT NULL,
             'age_min',     round(extract(epoch FROM (now() - (sh.created_c AT TIME ZONE 'Africa/Cairo')))/60)::int,
             'driver_name', sh.driver_name, 'driver_phone', sh.driver_phone,
             'others', coalesce((
                SELECT jsonb_agg(jsonb_build_object(
                         'bill_no', o2.bill_no, 'name', o2.customer_name,
                         'region', o2.cust_region, 'status', o2.status) ORDER BY o2.bill_no)
                  FROM trip_orders t3 JOIN orders o2 ON o2.id = t3.order_id
                 WHERE t3.trip_id = sh.trip_id AND t3.order_id <> sh.id
                   AND o2.status NOT IN ('cancelled')), '[]'::jsonb)
           ) ORDER BY sh.is_live DESC, sh.created_c DESC)
      FROM sh), '[]'::jsonb)
);
$fn$;

COMMENT ON FUNCTION public.get_open_transfers() IS
  'كروت تتبع التحويلات: التحويلة بمراحلها (إنشاء/تعيين/استلام/وصول) + عدّادات الأصناف المعلّقة لكل فرع';

GRANT EXECUTE ON FUNCTION public.get_open_transfers() TO anon, authenticated;

COMMIT;
