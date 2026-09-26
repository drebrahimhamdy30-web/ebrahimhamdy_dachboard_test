-- ═══════════════════════════════════════════════════════════════════
-- تتبع التحويلات بين الفروع — شاشة «تتبع التحويلات»
-- ═══════════════════════════════════════════════════════════════════
-- المشكلة: التحويلة بين الفروع بتمشي في حياتين منفصلتين:
--   1) طلب الصنف   → جدول task (type='تحويل'): الفرع الطالب في "user"
--      والفرع المطلوب منه في "branch"، وحالته pending/transferred/unavailable.
--   2) الشيلة نفسها → جدول orders كطلب يدوي bill_no='TRF-…'
--      (staff_notes='📌 تحويلة') بيتعيّن لطيار وبيمشي في رحلة.
-- مفيش رابط بين الاتنين، ومحدش بيشوف تحويلة الفرع التاني — فالفرع
-- بيسأل «طلعت مع مين؟ وصلت؟» بالتليفون.
--
-- الدالة دي بترجّع الصورتين مع بعض لفترة محدّدة:
--   shipments = كل تحويلة طالعة: الفرع المرسل/المستلم، مين عملها،
--               الطيار واسمه وتليفونه، رقم الرحلة، اتسلّمت/اتوصّلت،
--               وباقي طلبات نفس الرحلة (عشان تعرف الطيار ماشي بإيه).
--   requests  = طلبات التحويل (task) في نفس الفترة بحالتها وعمرها،
--               عشان الشاشة تكشف اللي لسه pending بعد ما التحويلة طلعت
--               («نسيوا الصنف»).
--
-- الفرع المستلم: التحويلات الجديدة بتتخزّن بـsource_data.to_branch
-- (شاشة التوزيع بقت تسأل عن الفرع). القديمة مالهاش حقل، فبنستنتجه من
-- اسم العميل ثم المنطقة عبر branch_from_text — استنتاج، والشاشة
-- بتوضّح إنه تخمين لما مايكونش صريح.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── فرع من نص حرّ: اسم أو alias أو منطقة اسم الفرع جوّاها ──
-- (ي/ى والمسافات مابيفرقوش: «سيديبشر» = «سيدى بشر»)
CREATE OR REPLACE FUNCTION public.branch_from_text(p_txt text)
RETURNS text LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $fn$
  WITH q AS (
    SELECT replace(replace(replace(replace(btrim(coalesce(p_txt,'')),'ي','ى'),'أ','ا'),'إ','ا'),' ','') AS t
  ), b AS (
    SELECT br.name,
           replace(replace(replace(replace(br.name,'ي','ى'),'أ','ا'),'إ','ا'),' ','') AS nn,
           (SELECT array_agg(replace(replace(replace(replace(a,'ي','ى'),'أ','ا'),'إ','ا'),' ',''))
              FROM unnest(coalesce(br.aliases,'{}'::text[])) a) AS an
      FROM branches br
  )
  SELECT b.name FROM b, q
   WHERE length(q.t) >= 3
     AND ( b.nn = q.t
        OR q.t = ANY(coalesce(b.an,'{}'::text[]))
        OR position(b.nn in q.t) > 0
        OR EXISTS (SELECT 1 FROM unnest(coalesce(b.an,'{}'::text[])) a
                    WHERE length(a) >= 3 AND position(a in q.t) > 0) )
   ORDER BY (b.nn = q.t) DESC, length(b.nn) DESC
   LIMIT 1;
$fn$;

COMMENT ON FUNCTION public.branch_from_text(text) IS
  'استنتاج اسم الفرع من نص حرّ (اسم/alias/منطقة) — للتحويلات القديمة اللي مالهاش فرع مستلم صريح';

-- ── الدالة الرئيسية ──
CREATE OR REPLACE FUNCTION public.get_transfer_tracking(
  p_from date DEFAULT NULL,
  p_to   date DEFAULT NULL
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
WITH rng AS (
  SELECT coalesce(p_from, (now() AT TIME ZONE 'Africa/Cairo')::date - 2) AS f,
         coalesce(p_to,   (now() AT TIME ZONE 'Africa/Cairo')::date)     AS t
),
-- التحويلات الطالعة (طلبات TRF)
ship AS (
  SELECT o.id, o.bill_no, o.branch_id, o.customer_name, o.cust_region, o.notes,
         o.status, o.driver_id, o.source_data,
         (o.bill_date    AT TIME ZONE 'Africa/Cairo') AS created_c,
         (o.picked_at    AT TIME ZONE 'Africa/Cairo') AS picked_c,
         (o.delivered_at AT TIME ZONE 'Africa/Cairo') AS delivered_c
    FROM orders o CROSS JOIN rng
   WHERE (o.bill_no LIKE 'TRF-%' OR o.staff_notes = '📌 تحويلة')
     AND (o.bill_date AT TIME ZONE 'Africa/Cairo')::date BETWEEN rng.f AND rng.t
),
sh AS (
  SELECT s.*,
         sb.name AS from_branch,
         nullif(s.source_data->>'to_branch','')                        AS to_exact,
         coalesce(nullif(s.source_data->>'to_branch',''),
                  public.branch_from_text(s.customer_name),
                  public.branch_from_text(s.cust_region))             AS to_branch,
         s.source_data->>'added_by'                                   AS created_by,
         tr.id AS trip_id, tr.trip_number, tr.status AS trip_status,
         d.full_name AS driver_name, d.phone AS driver_phone
    FROM ship s
    LEFT JOIN branches sb ON sb.id = s.branch_id
    LEFT JOIN LATERAL (
      SELECT t.id, t.trip_number, t.status, t.driver_id
        FROM trip_orders tox JOIN trips t ON t.id = tox.trip_id
       WHERE tox.order_id = s.id
       ORDER BY t.created_at DESC LIMIT 1
    ) tr ON true
    LEFT JOIN drivers d ON d.id = coalesce(tr.driver_id, s.driver_id)
),
-- طلبات التحويل (الأصناف)
req AS (
  SELECT t.id, t."user" AS req_user, t.branch AS from_branch,
         t.item_code, t.item_name, t.qty, t.cust_name,
         coalesce(nullif(btrim(coalesce(t.state,'')),''),'pending') AS state,
         t.company AS reply, t.note,
         (t.created_at AT TIME ZONE 'Africa/Cairo') AS created_c,
         (t.updated_at AT TIME ZONE 'Africa/Cairo') AS updated_c,
         round(extract(epoch FROM (now() - t.created_at)) / 60)::int  AS age_min,
         u.branch AS req_branch, u.full_name AS req_name
    FROM task t CROSS JOIN rng
    LEFT JOIN LATERAL (
      SELECT bu.branch, bu.full_name FROM branch_users bu
       WHERE bu.username = t."user" OR bu.mobile = t."user"
       ORDER BY bu.is_active DESC NULLS LAST LIMIT 1
    ) u ON true
   WHERE t.type = 'تحويل'
     AND (t.created_at AT TIME ZONE 'Africa/Cairo')::date BETWEEN rng.f AND rng.t
)
SELECT jsonb_build_object(
  'from', (SELECT f FROM rng), 'to', (SELECT t FROM rng),
  'shipments', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', sh.id, 'bill_no', sh.bill_no,
             'from_branch', sh.from_branch, 'to_branch', sh.to_branch,
             'to_exact', sh.to_exact IS NOT NULL,
             'to_hint', sh.customer_name, 'region', sh.cust_region,
             'created_by', sh.created_by, 'notes', sh.notes,
             'status', sh.status,
             'created',   to_char(sh.created_c,   'YYYY-MM-DD HH24:MI'),
             'picked',    to_char(sh.picked_c,    'HH24:MI'),
             'delivered', to_char(sh.delivered_c, 'HH24:MI'),
             'trip_number', sh.trip_number, 'trip_status', sh.trip_status,
             'driver_name', sh.driver_name, 'driver_phone', sh.driver_phone,
             'others', coalesce((
                SELECT jsonb_agg(jsonb_build_object(
                         'bill_no', o2.bill_no, 'name', o2.customer_name,
                         'region', o2.cust_region, 'status', o2.status,
                         'amount', round(coalesce(o2.total_bill_net,0))) ORDER BY o2.bill_no)
                  FROM trip_orders t2 JOIN orders o2 ON o2.id = t2.order_id
                 WHERE t2.trip_id = sh.trip_id AND t2.order_id <> sh.id), '[]'::jsonb)
           ) ORDER BY sh.created_c DESC)
      FROM sh), '[]'::jsonb),
  'requests', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', req.id, 'from_branch', req.from_branch,
             'req_branch', coalesce(req.req_branch, req.req_user),
             'req_name', coalesce(req.req_name, req.req_user),
             'item_code', req.item_code, 'item_name', req.item_name,
             'qty', req.qty, 'cust_name', req.cust_name,
             'state', req.state, 'reply', req.reply, 'note', req.note,
             'created', to_char(req.created_c, 'YYYY-MM-DD HH24:MI'),
             'updated', to_char(req.updated_c, 'YYYY-MM-DD HH24:MI'),
             'age_min', req.age_min
           ) ORDER BY req.created_c DESC)
      FROM req), '[]'::jsonb)
);
$fn$;

COMMENT ON FUNCTION public.get_transfer_tracking(date,date) IS
  'شاشة تتبع التحويلات: التحويلات الطالعة (طيار/رحلة/استلام) + طلبات التحويل بحالتها';

GRANT EXECUTE ON FUNCTION public.branch_from_text(text)            TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_transfer_tracking(date,date)  TO anon, authenticated;

-- ── الصفحة في القايمة + الصلاحيات (نفس صلاحيات «التحويلات») ──
INSERT INTO app_pages (key, file, title, section, sort_order, is_active)
VALUES ('transfer_track','transfer_track.html','تتبع التحويلات','المبيعات والعملاء',212,true)
ON CONFLICT (key) DO UPDATE
   SET file=excluded.file, title=excluded.title, section=excluded.section,
       sort_order=excluded.sort_order, is_active=true;

INSERT INTO page_permissions (role, page_key, page, can_view, can_edit, sort_order)
SELECT p.role, 'transfer_track', 'transfer_track.html', p.can_view, p.can_edit, 3
  FROM page_permissions p
 WHERE p.page_key = 'transfers'
ON CONFLICT (role, page) DO NOTHING;   -- المفتاح (role, page) مش page_key

COMMIT;
