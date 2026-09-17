-- ═══════════════════════════════════════════════════════════════════
-- تبويب «تحت الحد الأدنى» — إدارة المخزون
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-17)
--
-- الفكرة: أصناف بتسقط مننا، نحط لكل واحد حد أدنى في كل فرع، ولو الرصيد
-- قلّ عنه نعرف فورًا: نحوّله من فرع عنده فائض، وإلا نشتريه.
--
-- • الحدود بتتخزّن في stock_limit اللي موجود أصلًا (صف لكل صنف × فرع) —
--   نفس الجدول بتاع شاشة «حدود المخزون»، فالحدود القديمة بتظهر زي ما هي.
-- • الأرصدة من stock_flat (الفروع التلاتة في صف واحد، بيتحدّث كل 10 دقايق)
--   بدل الـ3 union على stock_mamora/san/bishr لكل صف.
-- • الفائض في فرع = رصيده − حده الأدنى هو كمان (ما نفضّيش فرع على حساب فرع).
-- • «قيد التحويل» من order_selections — نفس علامة شاشة الجرد/الطلبيات.
-- • معدل الاستهلاك الشهري من consumption_flat للاستئناس (أيام التغطية).
--
-- الحراسة: التعديل للأدمن في أي فرع، وباقي الأدوار في فرع التوكن بس.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- صنف واحد له صف واحد في كل فرع (كان ممكن يتكرر من الشاشة القديمة)
DELETE FROM stock_limit a USING stock_limit b
 WHERE a.item_code = b.item_code AND a.branch = b.branch AND a.id < b.id;
CREATE UNIQUE INDEX IF NOT EXISTS stock_limit_code_branch_uq ON stock_limit (item_code, branch);

-- ── قراءة: كل الأصناف المراقَبة بأرصدتها وحدودها في الفروع كلها ──────
CREATE OR REPLACE FUNCTION public.get_min_stock_alerts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_role text := coalesce(public.jwt_app_role(), '');
  v_pg   text := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role', '');
  v_rows jsonb;
BEGIN
  IF v_pg <> 'service_role' AND v_role = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'لازم تسجّل دخول');
  END IF;

  WITH lim AS (
    SELECT sl.item_code,
           max(sl.item_name) FILTER (WHERE nullif(btrim(sl.item_name), '') IS NOT NULL) AS item_name,
           max(sl.item_type) AS item_type,
           max(sl.min_stock) FILTER (WHERE sl.branch = 'المعمورة')  AS min_m,
           max(sl.min_stock) FILTER (WHERE sl.branch = 'سان ستيفانو') AS min_s,
           max(sl.min_stock) FILTER (WHERE sl.branch IN ('سيدى بشر','سيدي بشر')) AS min_b,
           max(sl.updated_at) AS updated_at
      FROM stock_limit sl
     WHERE sl.item_code IS NOT NULL
     GROUP BY sl.item_code
  ),
  pend AS (   -- طلبات تحويل لسه مفتوحة (الصف بيتمسح لما الطلب يتقفل)
    SELECT os.itm_code,
           bool_or(os.branch = 'المعمورة') AS p_m,
           bool_or(os.branch = 'سان ستيفانو') AS p_s,
           bool_or(os.branch IN ('سيدى بشر','سيدي بشر')) AS p_b
      FROM order_selections os GROUP BY os.itm_code
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'code', l.item_code,
           'name', coalesce(nullif(btrim(l.item_name), ''), sf.n, l.item_code),
           'unit', sf.u, 'company', sf.co, 'med', sf.med,
           'min_m', l.min_m, 'min_s', l.min_s, 'min_b', l.min_b,
           'qty_m', coalesce(sf.m_q, 0), 'qty_s', coalesce(sf.s_q, 0), 'qty_b', coalesce(sf.b_q, 0),
           'av_m', cf.av_mamora, 'av_s', cf.av_san, 'av_b', cf.av_bishr,
           'pend_m', coalesce(p.p_m, false), 'pend_s', coalesce(p.p_s, false), 'pend_b', coalesce(p.p_b, false),
           'updated_at', l.updated_at
         ) ORDER BY coalesce(nullif(btrim(l.item_name), ''), sf.n)), '[]'::jsonb)
    INTO v_rows
    FROM lim l
    LEFT JOIN stock_flat sf ON sf.itm_code = l.item_code
    LEFT JOIN consumption_flat cf ON cf.code = l.item_code
    LEFT JOIN pend p ON p.itm_code = l.item_code;

  RETURN jsonb_build_object('success', true, 'rows', v_rows,
    'my_branch', public.jwt_branch(), 'is_admin', v_role = 'admin',
    'stock_at', (SELECT max(src_max) FROM stock_flat_meta));
END $fn$;

REVOKE ALL ON FUNCTION public.get_min_stock_alerts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_min_stock_alerts() TO authenticated, service_role;

-- ── كتابة: حد أدنى لصنف في فرع (NULL = شيل الحد) ────────────────────
CREATE OR REPLACE FUNCTION public.set_stock_limit(p_code text, p_branch text, p_min numeric,
                                                  p_name text DEFAULT NULL, p_type text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_role  text := coalesce(public.jwt_app_role(), '');
  v_pg    text := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role', '');
  v_canon text;
  v_mine  text;
  v_code  text := btrim(coalesce(p_code, ''));
BEGIN
  IF v_pg <> 'service_role' AND v_role NOT IN ('admin','manager','employee','pharmacist','reviewer') THEN
    RETURN jsonb_build_object('success', false, 'error', 'تعديل الحدود مش ضمن صلاحياتك');
  END IF;
  IF v_code = '' THEN RETURN jsonb_build_object('success', false, 'error', 'كود الصنف ناقص'); END IF;

  SELECT b.name INTO v_canon FROM branches b
   WHERE replace(b.name,'ي','ى') = replace(btrim(coalesce(p_branch,'')),'ي','ى')
      OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases,'{}')) a
                  WHERE replace(a,'ي','ى') = replace(btrim(coalesce(p_branch,'')),'ي','ى'))
   LIMIT 1;
  IF v_canon IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'فرع غير معروف'); END IF;

  -- غير الأدمن: فرعه بس
  IF v_pg <> 'service_role' AND v_role <> 'admin' THEN
    SELECT b.name INTO v_mine FROM branches b
     WHERE replace(b.name,'ي','ى') = replace(btrim(coalesce(public.jwt_branch(),'')),'ي','ى')
        OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases,'{}')) a
                    WHERE replace(a,'ي','ى') = replace(btrim(coalesce(public.jwt_branch(),'')),'ي','ى'))
     LIMIT 1;
    IF v_mine IS NULL OR v_mine <> v_canon THEN
      RETURN jsonb_build_object('success', false, 'error', 'تقدر تعدّل حد فرعك بس');
    END IF;
  END IF;

  IF p_min IS NULL THEN
    DELETE FROM stock_limit WHERE item_code = v_code AND branch = v_canon;
    RETURN jsonb_build_object('success', true, 'deleted', true, 'branch', v_canon);
  END IF;
  IF p_min < 0 THEN RETURN jsonb_build_object('success', false, 'error', 'الحد الأدنى مايكونش بالسالب'); END IF;

  INSERT INTO stock_limit (item_code, item_name, item_type, branch, min_stock, updated_at)
  VALUES (v_code, nullif(btrim(coalesce(p_name,'')),''), nullif(btrim(coalesce(p_type,'')),''), v_canon, p_min, now())
  ON CONFLICT (item_code, branch) DO UPDATE
    SET min_stock  = excluded.min_stock,
        item_name  = coalesce(excluded.item_name, stock_limit.item_name),
        item_type  = coalesce(excluded.item_type, stock_limit.item_type),
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'branch', v_canon);
END $fn$;

REVOKE ALL ON FUNCTION public.set_stock_limit(text, text, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_stock_limit(text, text, numeric, text, text) TO authenticated, service_role;

COMMIT;

-- 2026-09-17 (بعدها بساعة): التبويب اللي كان في inventory_management.html اتشال —
-- المالك عنده شاشة «حدود المخزون» بتعمل نفس الدور، فاتسمّت «الحد الأدنى للمخزون»
-- (inventory_min.html) واتضاف فيها عمود «باقي الفروع» وزر طلب التحويل/الشراء.
-- الدالتين هنا زي ما هما: الشاشة بتنادي get_min_stock_alerts لأرصدة الفروع التلاتة.
UPDATE app_pages SET title = 'الحد الأدنى للمخزون' WHERE key = 'inventory_min';
