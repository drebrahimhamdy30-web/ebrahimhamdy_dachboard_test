-- ═══════════════════════════════════════════════════════════════════
-- الجرد: منع ازدواج التسجيل + تنضيف الصفوف المكررة القديمة
-- ═══════════════════════════════════════════════════════════════════
-- الضغطة الواحدة على «مطابق/غير مطابق» كانت بتتسجّل أكتر من مرة. مثال
-- حقيقي (سان ستيفانو، كود 6127، عمار صبحى البرديسى، 22/9/2026):
--     14:33:58.164 · 14:33:58.169 · 14:33:58.534 · 14:33:58.539
-- أربع صفوف بنفس الأرقام بالظبط في 375 جزء من الثانية — ده مش إنسان
-- بيدوس أربع مرات، ده نفس الطلب بيتبعت مرتين (مستمع حدث مكرر/مفيش قفل).
--
-- الأثر على تقرير «معدل الجرد اليومي» اللي بيتقيّم بيه الموظفين:
--   عمار صبحى البرديسى: 11,345 صف مقابل 7,418 صنف حقيقي (تضخيم 34.6%)
--   عبدالرحمن محمد علي:   5,006 مقابل 4,496 (10.2%)
--   محمد على:             9,367 مقابل 9,136 (2.5%)
--
-- الحل هنا (3 طبقات مع قفل الزر في الشاشة):
--   ① تنضيف: مسح الصفوف المتطابقة تمامًا (نفس الفرع والكود والموظف
--      واليوم **ونفس الأرقام**) مع الاحتفاظ بواحد. الصفوف اللي أرقامها
--      مختلفة = جرد حقيقي متكرر وبتفضل زي ما هي، وأي صف عليه مراجعة
--      (resolved/review_qty) مابيتمسحش خالص. المحذوف بيتخزّن في جدول
--      نسخة احتياطية قبل الحذف.
--   ② منع: submit_jard_audit بقت **تحدّث** الصف بدل ما تضيف صف جديد لو
--      نفس (فرع+كود+موظف) في نفس يوم القاهرة، وبقفل ذري بيسلسل الضغطتين
--      اللي بتوصلوا في نفس الملي ثانية.
--   ③ التقرير: get_jard_daily_stats بتعدّ **الأصناف المميزة** بدل الصفوف،
--      فحتى لو حصل تكرار تاني الأرقام تفضل صح.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ ① تنضيف الصفوف المكررة ═══
CREATE TABLE IF NOT EXISTS public.jard_audit_dups_removed
  AS SELECT * FROM public.jard_audit_log WHERE false;

COMMENT ON TABLE public.jard_audit_dups_removed IS
  'نسخة احتياطية من صفوف الجرد المكررة اللي اتمسحت في migrate_77 (2026-09-28)';

CREATE TEMP TABLE _dup_ids ON COMMIT DROP AS
WITH ranked AS (
  SELECT id, resolved, review_qty,
         row_number() OVER (
           PARTITION BY branch, code, audited_by,
                        (audited_at AT TIME ZONE 'Africa/Cairo')::date,
                        actual_qty, system_qty
           ORDER BY (review_qty IS NOT NULL) DESC, resolved DESC NULLS LAST, id ASC) rn
    FROM public.jard_audit_log
)
SELECT id FROM ranked
 WHERE rn > 1 AND review_qty IS NULL AND NOT coalesce(resolved, false);

INSERT INTO public.jard_audit_dups_removed
SELECT * FROM public.jard_audit_log WHERE id IN (SELECT id FROM _dup_ids);

DELETE FROM public.jard_audit_log WHERE id IN (SELECT id FROM _dup_ids);

-- ═══ ② التسجيل: تحديث بدل الازدواج ═══
CREATE OR REPLACE FUNCTION public.submit_jard_audit(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_sys    numeric;
  v_act    numeric;
  v_old    numeric;
  r        jard_audit_log%ROWTYPE;
BEGIN
  IF pg_role <> 'service_role' AND coalesce(app_role, '') NOT IN ('inventory', 'supervisor', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'تسجيل الجرد متاح لموظف الجرد / مشرف الجرد بس');
  END IF;
  IF v_code = '' OR v_branch = '' OR v_cat = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'بيانات ناقصة (الكود / الفرع / الفئة)');
  END IF;
  SELECT b.name INTO v_canon FROM branches b
   WHERE replace(b.name, 'ي', 'ى') = replace(v_branch, 'ي', 'ى')
      OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases, '{}')) a
                  WHERE replace(a, 'ي', 'ى') = replace(v_branch, 'ي', 'ى'))
   LIMIT 1;
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'فرع غير معروف: ' || v_branch);
  END IF;
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

  v_sys := CASE WHEN (p ->> 'system_qty') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'system_qty')::numeric END;
  v_act := CASE WHEN (p ->> 'actual_qty') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p ->> 'actual_qty')::numeric END;

  -- ⚠️ قفل ذري على (فرع+كود+موظف): الضغطتين اللي بيوصلوا في نفس الملي
  --    ثانية بيتسلسلوا، فالتانية بتلاقي صف التانية الأولى وتحدّثه.
  PERFORM pg_advisory_xact_lock(hashtext(v_canon || '|' || v_code || '|' || v_by));

  SELECT * INTO r FROM jard_audit_log
   WHERE branch = v_canon AND code = v_code AND audited_by = v_by
     AND (audited_at AT TIME ZONE 'Africa/Cairo')::date = (now() AT TIME ZONE 'Africa/Cairo')::date
   ORDER BY id DESC LIMIT 1;

  IF FOUND THEN
    v_old := r.actual_qty;
    UPDATE jard_audit_log SET
        category    = v_cat,
        itm_name_ar = coalesce(nullif(p ->> 'itm_name_ar', ''), itm_name_ar),
        itm_name_en = coalesce(nullif(p ->> 'itm_name_en', ''), itm_name_en),
        matched     = coalesce((p ->> 'matched')::boolean, false),
        system_qty  = v_sys,
        actual_qty  = v_act,
        exp_ym      = coalesce(v_exp, exp_ym),
        audited_at  = now(),
        -- الرقم اتغيّر؟ يبقى مراجعة المراجع بقت على رقم قديم — ترجع للمراجعة
        resolved    = CASE WHEN v_act IS DISTINCT FROM v_old THEN false ELSE resolved    END,
        resolved_by = CASE WHEN v_act IS DISTINCT FROM v_old THEN null  ELSE resolved_by END,
        resolved_at = CASE WHEN v_act IS DISTINCT FROM v_old THEN null  ELSE resolved_at END
     WHERE id = r.id
     RETURNING * INTO r;
    RETURN jsonb_build_object('success', true, 'id', r.id, 'updated', true, 'row', to_jsonb(r));
  END IF;

  INSERT INTO jard_audit_log (code, branch, category, itm_name_ar, itm_name_en, matched,
                              system_qty, actual_qty, audited_by, exp_ym)
  VALUES (v_code, v_canon, v_cat,
          nullif(p ->> 'itm_name_ar', ''), nullif(p ->> 'itm_name_en', ''),
          coalesce((p ->> 'matched')::boolean, false),
          v_sys, v_act, v_by, v_exp)
  RETURNING * INTO r;
  RETURN jsonb_build_object('success', true, 'id', r.id, 'row', to_jsonb(r));
END $function$;

-- ═══ ③ تقرير المعدل اليومي: الأصناف المميزة مش الصفوف ═══
CREATE OR REPLACE FUNCTION public.get_jard_daily_stats(p_from date, p_to date, p_branch text DEFAULT NULL::text)
 RETURNS TABLE(audit_date date, audited_by text, branch text, audits_count bigint)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (audited_at AT TIME ZONE 'Africa/Cairo')::date AS audit_date,
         COALESCE(NULLIF(trim(audited_by),''),'غير معروف') AS audited_by,
         COALESCE(NULLIF(trim(branch),''),'---')          AS branch,
         count(DISTINCT code)::bigint AS audits_count
  FROM public.jard_audit_log
  WHERE (p_from IS NULL OR (audited_at AT TIME ZONE 'Africa/Cairo')::date >= p_from)
    AND (p_to   IS NULL OR (audited_at AT TIME ZONE 'Africa/Cairo')::date <= p_to)
    AND (p_branch IS NULL OR p_branch = '' OR branch = p_branch)
  GROUP BY 1,2,3
$function$;

COMMIT;
