-- ═══════════════════════════════════════════════════════════════════
-- شاشة «مؤشر الأداء» — مقارنة الفروع في كل حاجة في السيستم
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-17)
--
-- get_kpi_dashboard(p_from, p_to) بترجّع صف لكل (فرع × يوم) فيه الأرقام
-- الخام (عدّادات ومجاميع) — مش نسب. الشاشة بتجمّع للفترة وبتحسب النسب
-- (بسط ÷ مقام) وبترسم الاتجاه اليومي، فالنسبة على الفترة مش متوسط نسب.
--
-- المصادر (اليوم = تاريخ القاهرة):
--   المبيعات   sales_items (فاتورة = store_name+bill_no، صافيها max(total_bill_net))
--              − returns_log (return_date متخزّن قاهرة حرفي)؛ الفرع من branch_map
--   التوصيل    orders: اليوم = coalesce(bill_date, created_at)؛ SLA من sla_rating
--              (ممتاز/جيد = في الوقت)؛ وقت التوصيل sla_actual_minutes (0..300)
--   التحضير    orders.prep_done_at − (last_activated_at|bill_date|created_at) − الإيقاف (0..180)
--   الجرد      jard_audit_log (matched)
--   التحويلات/الشراء  task type تحويل/شراء — state unavailable = مش متوفر
--   الماكينات  wallet type SALE (ammount)
--   التعاقدات  contract_invoices.total_bill
--   لم يصل     missing_items
--   المهام     task_done
--   الأسعار    price_changes
-- أسماء الفروع بتتوحّد (ي/ى + الأسماء البديلة من branches).
--
-- الحراسة: الأدمن أو دور ليه صلاحية الصفحة kpi في page_permissions.
-- ═══════════════════════════════════════════════════════════════════

INSERT INTO app_pages (key, file, title, section, sort_order, is_active)
VALUES ('kpi', 'kpi.html', 'مؤشر الأداء', 'نظرة عامة', 100, true)
ON CONFLICT (key) DO UPDATE SET file = EXCLUDED.file, title = EXCLUDED.title,
  section = EXCLUDED.section, sort_order = EXCLUDED.sort_order, is_active = true;

CREATE OR REPLACE FUNCTION public.get_kpi_dashboard(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_pg  text := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role', '');
  v_role text := coalesce(public.jwt_app_role(), '');
  t0 timestamptz;
  t1 timestamptz;
  v_rows jsonb;
BEGIN
  IF NOT (v_pg = 'service_role' OR v_role = 'admin'
          OR EXISTS (SELECT 1 FROM page_permissions pp WHERE pp.page_key = 'kpi' AND pp.role = v_role AND pp.can_view)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'مؤشر الأداء مش ضمن صلاحياتك');
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 400 THEN
    RETURN jsonb_build_object('success', false, 'error', 'اختار فترة صحيحة (سنة بالكتير)');
  END IF;
  t0 := p_from::timestamp AT TIME ZONE 'Africa/Cairo';
  t1 := (p_to + 1)::timestamp AT TIME ZONE 'Africa/Cairo';

  WITH bk AS (   -- مفتاح موحّد → اسم الفرع القياسي
    SELECT DISTINCT replace(k, 'ي', 'ى') AS k, b.name
      FROM branches b, unnest(array[b.name] || coalesce(b.aliases, '{}')) k
     WHERE coalesce(b.is_active, true)
  ),
  -- ── المبيعات ─────────────────────────────────────────
  bills AS (
    SELECT bm.branch, (s.bill_date AT TIME ZONE 'Africa/Cairo')::date AS day, s.bill_no,
           max(s.total_bill_net) AS net, bool_or(s.is_delivery) AS d, bool_or(s.is_contract) AS c
      FROM sales_items s JOIN branch_map bm ON bm.store_name = s.store_name
     WHERE s.bill_date >= t0 AND s.bill_date < t1 AND s.bill_status = 'Completed'
     GROUP BY 1, 2, s.store_name, s.bill_no
  ),
  sales AS (
    SELECT branch, day, count(*) AS bills, sum(net) AS sales_gross,
           count(*) FILTER (WHERE d AND NOT c) AS delivery_bills,
           coalesce(sum(net) FILTER (WHERE d AND NOT c), 0) AS delivery_net,
           coalesce(sum(net) FILTER (WHERE c), 0) AS contract_net
      FROM bills GROUP BY 1, 2
  ),
  rets AS (
    SELECT bk.name AS branch, r.return_date::date AS day,
           count(DISTINCT r.bill_no) AS returns_bills, sum(r.return_value) AS returns_value
      FROM returns_log r JOIN bk ON bk.k = replace(r.branch, 'ي', 'ى')
     WHERE r.return_date >= p_from::timestamp AND r.return_date < (p_to + 1)::timestamp
     GROUP BY 1, 2
  ),
  -- ── التوصيل والتحضير ─────────────────────────────────
  ords AS (
    SELECT b.name AS branch, (coalesce(o.bill_date, o.created_at) AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) AS orders,
           count(*) FILTER (WHERE o.status IN ('completed', 'delivered')) AS orders_done,
           count(*) FILTER (WHERE o.status = 'cancelled') AS orders_cancelled,
           count(*) FILTER (WHERE o.sla_rating IS NOT NULL) AS sla_rated,
           count(*) FILTER (WHERE o.sla_rating IN ('ممتاز', 'جيد')) AS sla_ok,
           count(*) FILTER (WHERE o.sla_actual_minutes BETWEEN 0 AND 300) AS dlv_n,
           coalesce(sum(o.sla_actual_minutes) FILTER (WHERE o.sla_actual_minutes BETWEEN 0 AND 300), 0) AS dlv_mins,
           count(*) FILTER (WHERE p.m BETWEEN 0 AND 180) AS prep_n,
           coalesce(sum(p.m) FILTER (WHERE p.m BETWEEN 0 AND 180), 0) AS prep_mins,
           coalesce(sum(o.total_bill_net) FILTER (WHERE o.status IN ('completed', 'delivered')), 0) AS orders_value
      FROM orders o JOIN branches b ON b.id = o.branch_id
      CROSS JOIN LATERAL (SELECT CASE WHEN o.prep_done_at IS NULL THEN NULL ELSE
             (extract(epoch FROM o.prep_done_at - coalesce(o.last_activated_at, o.bill_date, o.created_at))
              - coalesce(o.prep_hold_seconds, 0)) / 60.0 END AS m) p
     WHERE coalesce(o.bill_date, o.created_at) >= t0 AND coalesce(o.bill_date, o.created_at) < t1
     GROUP BY 1, 2
  ),
  -- ── الجرد ───────────────────────────────────────────
  jard AS (
    SELECT bk.name AS branch, (j.audited_at AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) AS jard_items, count(*) FILTER (WHERE j.matched) AS jard_matched
      FROM jard_audit_log j JOIN bk ON bk.k = replace(j.branch, 'ي', 'ى')
     WHERE j.audited_at >= t0 AND j.audited_at < t1
     GROUP BY 1, 2
  ),
  -- ── التحويلات والشراء ───────────────────────────────
  tasks AS (
    SELECT bk.name AS branch, (t.created_at AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) FILTER (WHERE t.type = 'تحويل') AS transfers,
           count(*) FILTER (WHERE t.type = 'تحويل' AND t.state = 'unavailable') AS transfers_unavail,
           count(*) FILTER (WHERE t.type = 'شراء') AS purchases,
           count(*) FILTER (WHERE t.type = 'شراء' AND t.state = 'unavailable') AS purchases_unavail
      FROM task t JOIN bk ON bk.k = replace(t.branch, 'ي', 'ى')
     WHERE t.created_at >= t0 AND t.created_at < t1 AND t.type IN ('تحويل', 'شراء')
     GROUP BY 1, 2
  ),
  -- ── الماكينات ───────────────────────────────────────
  wal AS (
    SELECT bk.name AS branch, (w."createdAt" AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) AS pos_n, coalesce(sum(w.ammount), 0) AS pos_value
      FROM wallet w JOIN bk ON bk.k = replace(w.branch, 'ي', 'ى')
     WHERE w."createdAt" >= t0 AND w."createdAt" < t1 AND w.type = 'SALE'
     GROUP BY 1, 2
  ),
  -- ── التعاقدات ───────────────────────────────────────
  ci AS (
    SELECT bk.name AS branch, (c.bill_date AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) AS contract_invoices, coalesce(sum(c.total_bill), 0) AS contract_value
      FROM contract_invoices c JOIN bk ON bk.k = replace(c.branch, 'ي', 'ى')
     WHERE c.bill_date >= t0 AND c.bill_date < t1
     GROUP BY 1, 2
  ),
  -- ── لم يصل من الشركات ───────────────────────────────
  miss AS (
    SELECT bk.name AS branch, (m.created_at AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) AS missing_items
      FROM missing_items m JOIN bk ON bk.k = replace(m.branch, 'ي', 'ى')
     WHERE m.created_at >= t0 AND m.created_at < t1
     GROUP BY 1, 2
  ),
  -- ── المهام المنفذة ──────────────────────────────────
  tdone AS (
    SELECT bk.name AS branch, d.done_on AS day, count(*) AS tasks_done
      FROM task_done d JOIN bk ON bk.k = replace(d.branch, 'ي', 'ى')
     WHERE d.done_on BETWEEN p_from AND p_to
     GROUP BY 1, 2
  ),
  -- ── تغييرات الأسعار ─────────────────────────────────
  pch AS (
    SELECT bk.name AS branch, (p.changed_at AT TIME ZONE 'Africa/Cairo')::date AS day,
           count(*) AS price_changes, count(*) FILTER (WHERE p.reviewed) AS price_reviewed
      FROM price_changes p JOIN bk ON bk.k = replace(p.branch, 'ي', 'ى')
     WHERE p.changed_at >= t0 AND p.changed_at < t1
     GROUP BY 1, 2
  ),
  keys AS (
    SELECT branch, day FROM sales UNION SELECT branch, day FROM rets UNION SELECT branch, day FROM ords
    UNION SELECT branch, day FROM jard UNION SELECT branch, day FROM tasks UNION SELECT branch, day FROM wal
    UNION SELECT branch, day FROM ci UNION SELECT branch, day FROM miss UNION SELECT branch, day FROM tdone
    UNION SELECT branch, day FROM pch
  )
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'branch', k.branch, 'day', k.day,
           'bills', s.bills, 'sales_gross', round(s.sales_gross, 2),
           'delivery_bills', s.delivery_bills, 'delivery_net', round(s.delivery_net, 2), 'contract_net', round(s.contract_net, 2),
           'returns_bills', r.returns_bills, 'returns_value', round(r.returns_value, 2),
           'orders', o.orders, 'orders_done', o.orders_done, 'orders_cancelled', o.orders_cancelled,
           'orders_value', round(o.orders_value, 2),
           'sla_rated', o.sla_rated, 'sla_ok', o.sla_ok, 'dlv_n', o.dlv_n, 'dlv_mins', round(o.dlv_mins, 1),
           'prep_n', o.prep_n, 'prep_mins', round(o.prep_mins, 1),
           'jard_items', j.jard_items, 'jard_matched', j.jard_matched,
           'transfers', t.transfers, 'transfers_unavail', t.transfers_unavail,
           'purchases', t.purchases, 'purchases_unavail', t.purchases_unavail,
           'pos_n', w.pos_n, 'pos_value', round(w.pos_value, 2),
           'contract_invoices', c.contract_invoices, 'contract_value', round(c.contract_value, 2),
           'missing_items', m.missing_items, 'tasks_done', d.tasks_done,
           'price_changes', p.price_changes, 'price_reviewed', p.price_reviewed
         )) ORDER BY k.day, k.branch), '[]'::jsonb)
    INTO v_rows
    FROM keys k
    LEFT JOIN sales s ON s.branch = k.branch AND s.day = k.day
    LEFT JOIN rets  r ON r.branch = k.branch AND r.day = k.day
    LEFT JOIN ords  o ON o.branch = k.branch AND o.day = k.day
    LEFT JOIN jard  j ON j.branch = k.branch AND j.day = k.day
    LEFT JOIN tasks t ON t.branch = k.branch AND t.day = k.day
    LEFT JOIN wal   w ON w.branch = k.branch AND w.day = k.day
    LEFT JOIN ci    c ON c.branch = k.branch AND c.day = k.day
    LEFT JOIN miss  m ON m.branch = k.branch AND m.day = k.day
    LEFT JOIN tdone d ON d.branch = k.branch AND d.day = k.day
    LEFT JOIN pch   p ON p.branch = k.branch AND p.day = k.day;

  RETURN jsonb_build_object('success', true, 'from', p_from, 'to', p_to,
    'branches', (SELECT jsonb_agg(name ORDER BY sort_order) FROM branches WHERE coalesce(is_active, true)),
    'rows', v_rows);
END $fn$;

REVOKE ALL ON FUNCTION public.get_kpi_dashboard(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kpi_dashboard(date, date) TO authenticated, service_role;

-- ⚠️ اتعدّل بعد التطبيق (kpi_dashboard_prep_from_logs): وقت التحضير بيتحسب بس للطلبات
--    اللي ليها حدث order_prepared (شاشة المحضّر) — الفروع اللي مش شغّالة بالمحضّر
--    كان prep_done_at بيتحط تلقائي فمتوسطها بيطلع ~0 دقيقة ويكسب الترتيب غلط:
--      pl AS (SELECT DISTINCT lg.order_id FROM order_logs lg
--              WHERE lg.event = 'order_prepared'
--                AND lg.created_at >= t0 - interval '1 day' AND lg.created_at < t1 + interval '1 day')
--      ... FROM orders o JOIN branches b ON b.id = o.branch_id LEFT JOIN pl ON pl.order_id = o.id
--      ... CASE WHEN o.prep_done_at IS NULL OR pl.order_id IS NULL THEN NULL ELSE ...
