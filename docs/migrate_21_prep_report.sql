-- ═══════════════════════════════════════════════════════════════════
-- تقرير تحضير الطلبات — شاشة التقارير (تبويب «تحضير الطلبات»)
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-16)
--
-- المصدر: order_logs event='order_prepared' (prep.html بيكتبه مع اسم المحضّر
-- من حسابه) + orders.prep_done_at.
--
-- • الفاتورة تتحسب مرة واحدة: آخر «تم التحضير» ليها (لو رجعت للتحضير
--   واتحضّرت تاني ماتتعدّش مرتين).
-- • اليوم = يوم التحضير بتوقيت القاهرة.
-- • المتوسط اليومي للموظف = فواتيره ÷ الأيام اللي حضّر فيها فعلًا (مش أيام
--   الفترة كلها — اليوم اللي ماشتغلش فيه مايقلّلش متوسطه).
-- • وقت التحضير = من ما الطلب بقى نشط (last_activated_at، وإلا bill_date)
--   لحد «تم التحضير» − مدة الإيقاف. ده نفس أساس «وقت الطلب الحقيقي».
--   ⚠️ بيشمل وقت الانتظار في الطابور، مش وقت الإيد بس — مفيش حدث «بدأ تحضير».
-- • وقت سالب أو أكتر من 180 دقيقة = غير طبيعي (طلب اتفعّل تاني/اتعدّل):
--   بيتعدّ في الفواتير بس مش داخل في متوسط الوقت، وعدده بيرجع لوحده.
-- • الحراسة: أدمن = كل الفروع أو فرع؛ مدير = فرعه بس (من التوكن).
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_prep_report(p_from date, p_to date, p_branch uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_role text := coalesce(public.jwt_app_role(), '');
  v_pg   text := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role', '');
  v_br   uuid := p_branch;
  v_res  jsonb;
BEGIN
  IF v_pg <> 'service_role' AND v_role NOT IN ('admin','manager') THEN
    RETURN jsonb_build_object('success', false, 'error', 'التقرير للأدمن والمديرين بس');
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RETURN jsonb_build_object('success', false, 'error', 'اختار فترة صحيحة');
  END IF;
  IF v_role = 'manager' THEN
    SELECT b.id INTO v_br FROM branches b
     WHERE replace(b.name,'ي','ى') = replace(btrim(coalesce(public.jwt_branch(),'')),'ي','ى')
        OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases,'{}')) a
                    WHERE replace(a,'ي','ى') = replace(btrim(coalesce(public.jwt_branch(),'')),'ي','ى'))
     LIMIT 1;
    IF v_br IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'مش لاقي فرعك');
    END IF;
  END IF;

  WITH ev AS (
    SELECT DISTINCT ON (lg.order_id) lg.order_id, btrim(coalesce(lg.user_name,'')) AS who, lg.created_at AS log_at
      FROM order_logs lg
     WHERE lg.event = 'order_prepared'
       AND (lg.created_at AT TIME ZONE 'Africa/Cairo')::date BETWEEN p_from - 1 AND p_to + 1
     ORDER BY lg.order_id, lg.created_at DESC
  ), x AS (
    SELECT e.who, o.branch_id, b.name AS branch,
           (coalesce(o.prep_done_at, e.log_at) AT TIME ZONE 'Africa/Cairo')::date AS day,
           ( extract(epoch FROM coalesce(o.prep_done_at, e.log_at)
                              - coalesce(o.last_activated_at, o.bill_date, o.created_at))
             - coalesce(o.prep_hold_seconds, 0) ) / 60.0 AS mins
      FROM ev e
      JOIN orders o ON o.id = e.order_id
      LEFT JOIN branches b ON b.id = o.branch_id
     WHERE (v_br IS NULL OR o.branch_id = v_br)
  ), f AS (
    SELECT *, (mins >= 0 AND mins <= 180) AS ok FROM x WHERE day BETWEEN p_from AND p_to
  ), per_user AS (
    SELECT who, string_agg(DISTINCT branch, '، ') AS branches,
           count(*) AS invoices,
           count(DISTINCT day) AS days,
           round(count(*)::numeric / nullif(count(DISTINCT day),0), 1) AS per_day,
           round(avg(mins) FILTER (WHERE ok)::numeric, 1) AS avg_mins,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY mins) FILTER (WHERE ok))::numeric, 1) AS median_mins,
           round((percentile_cont(0.9) WITHIN GROUP (ORDER BY mins) FILTER (WHERE ok))::numeric, 1) AS p90_mins,
           count(*) FILTER (WHERE NOT ok) AS outliers,
           min(day) AS first_day, max(day) AS last_day
      FROM f GROUP BY who
  ), per_day AS (
    SELECT day, who, count(*) AS invoices, round(avg(mins) FILTER (WHERE ok)::numeric, 1) AS avg_mins
      FROM f GROUP BY day, who
  )
  SELECT jsonb_build_object(
    'success', true,
    'branch_id', v_br,
    'totals', (SELECT jsonb_build_object(
        'invoices', count(*),
        'preparers', count(DISTINCT who),
        'days', count(DISTINCT day),
        'per_day', round(count(*)::numeric / nullif(count(DISTINCT day),0), 1),
        'avg_mins', round(avg(mins) FILTER (WHERE ok)::numeric, 1),
        'median_mins', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY mins) FILTER (WHERE ok))::numeric, 1),
        'outliers', count(*) FILTER (WHERE NOT ok)) FROM f),
    'per_user', coalesce((SELECT jsonb_agg(to_jsonb(u) ORDER BY u.invoices DESC) FROM per_user u), '[]'::jsonb),
    'per_day',  coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.day DESC, d.invoices DESC) FROM per_day d), '[]'::jsonb)
  ) INTO v_res;
  RETURN v_res;
END $fn$;

REVOKE ALL ON FUNCTION public.get_prep_report(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_prep_report(date, date, uuid) TO authenticated, service_role;
