-- ═══════════════════════════════════════════════════════════════════
-- تسجيل الجرد مباشرة في القاعدة بدل ويبهوك n8n (jard_audit_log)
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-16)
--
-- ليه:
--   • ويبهوك n8n كان مجرد وسيط INSERT — بس نود الإدخال فيه قايمة أعمدة
--     ثابتة، فأي حقل جديد (زي exp_ym) كان بيترمي من غير خطأ.
--   • الويبهوك مفتوح من غير أي تسجيل دخول: أي حد يعرف الرابط كان يقدر
--     يسجّل جرد باسم أي موظف. الحارس كان في المتصفح بس.
--
-- الحراسة هنا على السيرفر:
--   • الدور: inventory / supervisor / admin (أو service_role)
--   • audited_by بييجي من التوكن (full_name) — مش من الشاشة
--   • «دخول عام للفرع» (الاسم = اسم فرع) مرفوض
--   • موظف الجرد يسجّل في فرعه بس — المشرف والأدمن أي فرع
--   • الفرع بيتخزّن بالاسم القياسي من جدول branches (ى/ي والأسماء البديلة)
--   • exp_ym لازم YYYY-MM
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.submit_jard_audit(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  app_role text  := public.jwt_app_role();
  jwt_name text  := btrim(coalesce(claims ->> 'full_name', claims -> 'app_metadata' ->> 'full_name', ''));
  jwt_br   text  := btrim(coalesce(public.jwt_branch(), ''));
  v_branch text  := btrim(coalesce(p ->> 'branch', ''));
  v_code   text  := btrim(coalesce(p ->> 'code', ''));
  v_cat    text  := btrim(coalesce(p ->> 'category', ''));
  v_by     text;
  v_exp    text  := nullif(btrim(coalesce(p ->> 'exp_ym', '')), '');
  v_canon  text;
  v_jcanon text;
  r        jard_audit_log%ROWTYPE;
BEGIN
  IF pg_role <> 'service_role' AND coalesce(app_role, '') NOT IN ('inventory', 'supervisor', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'تسجيل الجرد متاح لموظف الجرد / مشرف الجرد بس');
  END IF;

  IF v_code = '' OR v_branch = '' OR v_cat = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'بيانات ناقصة (الكود / الفرع / الفئة)');
  END IF;

  -- الفرع بالاسم القياسي
  SELECT b.name INTO v_canon FROM branches b
   WHERE replace(b.name, 'ي', 'ى') = replace(v_branch, 'ي', 'ى')
      OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases, '{}')) a
                  WHERE replace(a, 'ي', 'ى') = replace(v_branch, 'ي', 'ى'))
   LIMIT 1;
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'فرع غير معروف: ' || v_branch);
  END IF;

  -- الاسم من التوكن — مايتزوّرش من الشاشة
  v_by := CASE WHEN jwt_name <> '' THEN jwt_name ELSE btrim(coalesce(p ->> 'audited_by', '')) END;
  IF v_by = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'اسم الموظف ناقص');
  END IF;

  IF EXISTS (SELECT 1 FROM branches b
              WHERE replace(b.name, 'ي', 'ى') = replace(v_by, 'ي', 'ى')
                 OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases, '{}')) a
                             WHERE replace(a, 'ي', 'ى') = replace(v_by, 'ي', 'ى'))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'لا يمكن تسجيل الجرد من «دخول عام للفرع» — سجّل باسمك');
  END IF;

  IF app_role = 'inventory' AND jwt_br <> '' THEN
    SELECT b.name INTO v_jcanon FROM branches b
     WHERE replace(b.name, 'ي', 'ى') = replace(jwt_br, 'ي', 'ى')
        OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases, '{}')) a
                    WHERE replace(a, 'ي', 'ى') = replace(jwt_br, 'ي', 'ى'))
     LIMIT 1;
    IF coalesce(v_jcanon, jwt_br) <> v_canon THEN
      RETURN jsonb_build_object('success', false, 'error', 'مينفعش تسجّل جرد لفرع غير فرعك (' || jwt_br || ')');
    END IF;
  END IF;

  IF v_exp IS NOT NULL AND v_exp !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'صيغة الصلاحية لازم شهر/سنة');
  END IF;

  INSERT INTO jard_audit_log (code, branch, category, itm_name_ar, itm_name_en, matched,
                              system_qty, actual_qty, audited_by, exp_ym)
  VALUES (v_code, v_canon, v_cat,
          nullif(p ->> 'itm_name_ar', ''), nullif(p ->> 'itm_name_en', ''),
          coalesce((p ->> 'matched')::boolean, false),
          CASE WHEN (p ->> 'system_qty') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'system_qty')::numeric END,
          CASE WHEN (p ->> 'actual_qty') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'actual_qty')::numeric END,
          v_by, v_exp)
  RETURNING * INTO r;

  RETURN jsonb_build_object('success', true, 'id', r.id, 'row', to_jsonb(r));
END $fn$;

REVOKE ALL ON FUNCTION public.submit_jard_audit(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_jard_audit(jsonb) TO authenticated, service_role;
