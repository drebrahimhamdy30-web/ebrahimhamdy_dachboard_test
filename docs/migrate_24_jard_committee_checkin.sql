-- ═══════════════════════════════════════════════════════════════════
-- لجنة الجرد: موظف الجرد بيختار الفرع اللي هيجرد فيه وقت الدخول
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-17)
--
-- موظفين الجرد بقوا لجنة بتلف على الفروع. الفرع اللي على الحساب (JWT
-- app_metadata.branch) بقى «فرع أساسي» بس، والفرع الفعلي بيتحدد يوميًا.
--
-- • jard_checkins: سجل «دخل يجرد في فرع X» (مين/فين/إمتى) — مرجع للجنة.
-- • jard_checkin(p_branch): بيسجّل ويرجّع الاسم القياسي للفرع.
-- • submit_jard_audit: اتشال شرط «موظف الجرد في فرعه بس» — كان هيرفض
--   أي جرد في فرع غير فرع الحساب. باقي الحراسة زي ما هي (الدور، الاسم من
--   التوكن، منع الدخول العام، الفرع لازم يكون فرع حقيقي).
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.jard_checkins (
  id            bigserial PRIMARY KEY,
  username      text,
  full_name     text,
  role          text,
  home_branch   text,                         -- فرع الحساب
  branch        text NOT NULL,                -- الفرع اللي اختاره
  checked_in_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_jard_checkins_at ON public.jard_checkins (checked_in_at DESC);
ALTER TABLE public.jard_checkins ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS jard_checkins_read ON public.jard_checkins;
CREATE POLICY jard_checkins_read ON public.jard_checkins FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.jard_checkins FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.jard_checkins TO authenticated;

CREATE OR REPLACE FUNCTION public.jard_checkin(p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_role text  := coalesce(public.jwt_app_role(), '');
  v_canon text;
BEGIN
  IF v_role NOT IN ('inventory', 'supervisor', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'اختيار فرع الجرد لموظفين الجرد بس');
  END IF;
  SELECT b.name INTO v_canon FROM branches b
   WHERE coalesce(b.is_active, true)
     AND (replace(b.name,'ي','ى') = replace(btrim(coalesce(p_branch,'')),'ي','ى')
          OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases,'{}')) a
                      WHERE replace(a,'ي','ى') = replace(btrim(coalesce(p_branch,'')),'ي','ى')))
   LIMIT 1;
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'فرع غير معروف');
  END IF;
  INSERT INTO jard_checkins (username, full_name, role, home_branch, branch)
  VALUES (claims -> 'app_metadata' ->> 'username', claims -> 'app_metadata' ->> 'full_name', v_role,
          public.jwt_branch(), v_canon);
  RETURN jsonb_build_object('success', true, 'branch', v_canon);
END $fn$;

REVOKE ALL ON FUNCTION public.jard_checkin(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jard_checkin(text) TO authenticated, service_role;

COMMIT;

-- submit_jard_audit: نفس migrate_19 بالظبط من غير بلوك «موظف الجرد في فرعه بس»
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
  v_branch text  := btrim(coalesce(p ->> 'branch', ''));
  v_code   text  := btrim(coalesce(p ->> 'code', ''));
  v_cat    text  := btrim(coalesce(p ->> 'category', ''));
  v_by     text;
  v_exp    text  := nullif(btrim(coalesce(p ->> 'exp_ym', '')), '');
  v_canon  text;
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

  -- لجنة الجرد (2026-09-17): موظف الجرد بيجرد في أي فرع — الفرع من اختياره وقت الدخول

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
