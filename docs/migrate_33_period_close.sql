-- ═══════════════════════════════════════════════════════════════════
-- إقفال الفترة — تبويب «الرصيد الحالي» في سجل الإغلاقات
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-21)
--
-- الفكرة: المحاسب يراجع رصيد الفرع، ولما يطابق الفعلي يقفل الفترة لحد
-- تاريخ معيّن. النقطة دي بتبقى «آخر نقطة مظبوطة»: أي خلل بعد كده محصور
-- في الحركات اللي بعدها بس، والحركات اللي قبلها مايتلمسش فيها حاجة.
--
-- • pos_period_closes: صف لكل إقفال (فرع، لحد تاريخ، الرصيد، مين قفل).
--   الإقفال المفتوح = reopened_at IS NULL. الأدمن بس يقدر يفتح إقفال.
-- • pos_close_period(): بيحسب رصيد النظام لحد التاريخ بنفس معادلة الشاشة
--   (رصيد البداية + الإغلاقات − التحويلات) ويرفض لو الفعلي مختلف — قرار
--   المالك: مفيش تسوية تلقائية، لازم الفرق يتفهم ويتصلّح الأول.
-- • بعد الإقفال: أي تعديل/حذف/إضافة بتاريخ ≤ تاريخ آخر إقفال مرفوض من
--   السيرفر (تريجرات على pos_shifts / pos_wallet_transfers /
--   pos_manual_transfers / pos_branch_opening) — مش بإخفاء الزراير.
--   الاتصال المباشر بالقاعدة (n8n/postgres/service_role) مستثنى عشان
--   المزامنات ماتقفش.
--
-- اليوم المحاسبي = يوم القاهرة، زي ما الشاشة بتحسبه بالظبط.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.pos_period_closes (
  id          bigserial PRIMARY KEY,
  branch      text        NOT NULL,
  upto        date        NOT NULL,          -- الإقفال شامل اليوم ده
  balance     numeric(14,2) NOT NULL,        -- الرصيد المتفق عليه عند النقطة دي
  note        text,
  closed_by   text,
  closed_at   timestamptz NOT NULL DEFAULT now(),
  reopened_by text,
  reopened_at timestamptz,
  reopen_note text
);
CREATE UNIQUE INDEX IF NOT EXISTS pos_period_closes_open_uq
  ON public.pos_period_closes (branch, upto) WHERE reopened_at IS NULL;
CREATE INDEX IF NOT EXISTS pos_period_closes_branch_ix
  ON public.pos_period_closes (branch, upto DESC);

ALTER TABLE public.pos_period_closes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pos_period_closes_read ON public.pos_period_closes;
CREATE POLICY pos_period_closes_read ON public.pos_period_closes
  FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.pos_period_closes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.pos_period_closes TO authenticated;
GRANT ALL ON public.pos_period_closes TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.pos_period_closes_id_seq TO service_role;

-- ── آخر إقفال مفتوح لفرع ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pos_last_close(p_branch text)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
  SELECT max(c.upto) FROM pos_period_closes c
   WHERE c.reopened_at IS NULL
     AND replace(c.branch, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى');
$fn$;
GRANT EXECUTE ON FUNCTION public.pos_last_close(text) TO authenticated, service_role;

-- ── رصيد النظام لفرع لحد تاريخ (نفس معادلة الشاشة) ──────────────────
CREATE OR REPLACE FUNCTION public.pos_balance_upto(p_branch text, p_upto date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
  WITH b AS (SELECT replace(btrim(coalesce(p_branch, '')), 'ي', 'ى') AS k),
  opening AS (
    SELECT coalesce(max(o.opening_balance), 0) AS amt, coalesce(max(o.as_of), DATE '2000-01-01') AS as_of
      FROM pos_branch_opening o, b WHERE replace(o.branch, 'ي', 'ى') = b.k
  ),
  closures AS (   -- الإغلاق الموجب توريد والسالب صرف — المحصلة هي المجموع
    SELECT coalesce(sum(s.grand_total), 0) AS amt
      FROM pos_shifts s, b, opening op
     WHERE replace(s.branch, 'ي', 'ى') = b.k
       AND coalesce((s.closed_at AT TIME ZONE 'Africa/Cairo')::date, s.shift_date) BETWEEN op.as_of AND p_upto
  ),
  wallets AS (
    SELECT coalesce(sum(w.amount), 0) AS amt
      FROM pos_wallet_transfers w, b, opening op
     WHERE replace(w.branch, 'ي', 'ى') = b.k
       AND (w.created_at AT TIME ZONE 'Africa/Cairo')::date BETWEEN op.as_of AND p_upto
  ),
  manuals AS (
    SELECT coalesce(sum(m.amount), 0) AS amt
      FROM pos_manual_transfers m, b, opening op
     WHERE replace(m.branch, 'ي', 'ى') = b.k
       AND (m.txn_date AT TIME ZONE 'Africa/Cairo')::date BETWEEN op.as_of AND p_upto
  )
  SELECT round((SELECT amt FROM opening) + (SELECT amt FROM closures)
              - (SELECT amt FROM wallets) - (SELECT amt FROM manuals), 2);
$fn$;
GRANT EXECUTE ON FUNCTION public.pos_balance_upto(text, date) TO authenticated, service_role;

-- ── إقفال فترة (محاسب/أدمن) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pos_close_period(p_branch text, p_upto date, p_actual numeric,
                                                   p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_role  text  := coalesce(public.jwt_app_role(), '');
  v_pg    text  := coalesce(claims ->> 'role', '');
  v_canon text;
  v_last  date;
  v_sys   numeric;
  v_diff  numeric;
  v_who   text;
  r       pos_period_closes%ROWTYPE;
BEGIN
  IF v_pg <> 'service_role' AND v_role NOT IN ('accountant', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'إقفال الفترة للمحاسب والأدمن بس');
  END IF;

  SELECT b.name INTO v_canon FROM branches b
   WHERE replace(b.name, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى')
      OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases, '{}')) a
                  WHERE replace(a, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى'))
   LIMIT 1;
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'فرع غير معروف');
  END IF;

  IF p_upto IS NULL OR p_upto > (now() AT TIME ZONE 'Africa/Cairo')::date THEN
    RETURN jsonb_build_object('success', false, 'error', 'تاريخ الإقفال لازم يكون النهاردة أو قبله');
  END IF;

  v_last := public.pos_last_close(v_canon);
  IF v_last IS NOT NULL AND p_upto <= v_last THEN
    RETURN jsonb_build_object('success', false, 'error',
      'الفترة مقفولة لحد ' || v_last || ' — اختار تاريخ بعده، أو افتح الإقفال الأول');
  END IF;

  v_sys  := public.pos_balance_upto(v_canon, p_upto);
  v_diff := round(coalesce(p_actual, 0) - v_sys, 2);
  IF abs(v_diff) > 0.009 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'الرصيد الفعلي مش مطابق — النظام ' || trim(to_char(v_sys, 'FM999999999990.00'))
      || ' والفعلي ' || trim(to_char(coalesce(p_actual, 0), 'FM999999999990.00'))
      || ' (فرق ' || trim(to_char(v_diff, 'FM999999999990.00')) || '). صلّح الفرق الأول وبعدين اقفل.',
      'system', v_sys, 'actual', coalesce(p_actual, 0), 'diff', v_diff);
  END IF;

  v_who := btrim(coalesce(claims -> 'app_metadata' ->> 'full_name',
                          claims -> 'app_metadata' ->> 'username', ''));
  INSERT INTO pos_period_closes (branch, upto, balance, note, closed_by)
  VALUES (v_canon, p_upto, v_sys, nullif(btrim(coalesce(p_note, '')), ''), nullif(v_who, ''))
  RETURNING * INTO r;

  RETURN jsonb_build_object('success', true, 'row', to_jsonb(r), 'balance', v_sys);
END $fn$;
REVOKE ALL ON FUNCTION public.pos_close_period(text, date, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_close_period(text, date, numeric, text) TO authenticated, service_role;

-- ── فتح إقفال (أدمن بس) ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pos_reopen_period(p_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_role text  := coalesce(public.jwt_app_role(), '');
  v_pg   text  := coalesce(claims ->> 'role', '');
  v_who  text;
  r      pos_period_closes%ROWTYPE;
BEGIN
  IF v_pg <> 'service_role' AND v_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'فتح الإقفال للأدمن بس');
  END IF;
  SELECT * INTO r FROM pos_period_closes WHERE id = p_id;
  IF r.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'الإقفال مش موجود'); END IF;
  IF r.reopened_at IS NOT NULL THEN RETURN jsonb_build_object('success', false, 'error', 'الإقفال مفتوح بالفعل'); END IF;
  IF EXISTS (SELECT 1 FROM pos_period_closes c
              WHERE c.branch = r.branch AND c.reopened_at IS NULL AND c.upto > r.upto) THEN
    RETURN jsonb_build_object('success', false, 'error', 'في إقفال أحدث — افتحه الأول');
  END IF;

  v_who := btrim(coalesce(claims -> 'app_metadata' ->> 'full_name',
                          claims -> 'app_metadata' ->> 'username', ''));
  UPDATE pos_period_closes
     SET reopened_by = nullif(v_who, ''), reopened_at = now(),
         reopen_note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = p_id RETURNING * INTO r;
  RETURN jsonb_build_object('success', true, 'row', to_jsonb(r));
END $fn$;
REVOKE ALL ON FUNCTION public.pos_reopen_period(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_reopen_period(bigint, text) TO authenticated, service_role;

-- ── الحارس: ممنوع المساس بحركة داخل فترة مقفولة ─────────────────────
-- ⚠️ الصف بيتقرا كـjsonb مش OLD.field: تريجر واحد لأربع جداول، وأي إشارة
--    لعمود مش موجود في الجدول الحالي بتفشل وقت التنفيذ حتى لو في فرع CASE
--    مش بيتنفّذ.
CREATE OR REPLACE FUNCTION public.trg_block_closed_period()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_claims text := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '');
  v_rows   jsonb[];
  v_row    jsonb;
  v_branch text;
  v_day    date;
  v_last   date;
BEGIN
  -- الاتصال المباشر بالقاعدة (n8n / postgres / service_role) مستثنى
  IF v_claims = '' OR coalesce(v_claims::jsonb ->> 'role', '') = 'service_role' THEN
    RETURN coalesce(NEW, OLD);
  END IF;

  -- القديم والجديد الاتنين (نقل حركة من فترة مقفولة أو ليها)
  v_rows := ARRAY[]::jsonb[];
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_rows := v_rows || to_jsonb(OLD); END IF;
  IF TG_OP IN ('UPDATE', 'INSERT') THEN v_rows := v_rows || to_jsonb(NEW); END IF;

  FOREACH v_row IN ARRAY v_rows LOOP
    v_branch := v_row ->> 'branch';
    v_day := CASE TG_TABLE_NAME
               WHEN 'pos_shifts' THEN coalesce(
                      ((v_row ->> 'closed_at')::timestamptz AT TIME ZONE 'Africa/Cairo')::date,
                      (v_row ->> 'shift_date')::date)
               WHEN 'pos_wallet_transfers' THEN ((v_row ->> 'created_at')::timestamptz AT TIME ZONE 'Africa/Cairo')::date
               WHEN 'pos_manual_transfers' THEN ((v_row ->> 'txn_date')::timestamptz   AT TIME ZONE 'Africa/Cairo')::date
               WHEN 'pos_branch_opening'   THEN (v_row ->> 'as_of')::date
             END;
    IF v_branch IS NULL OR v_day IS NULL THEN CONTINUE; END IF;
    v_last := public.pos_last_close(v_branch);
    IF v_last IS NOT NULL AND v_day <= v_last THEN
      RAISE EXCEPTION 'الفترة مقفولة لفرع % لحد % — لازم الأدمن يفتح الإقفال الأول', v_branch, v_last
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  RETURN coalesce(NEW, OLD);
END $fn$;

DROP TRIGGER IF EXISTS trg_closed_period ON public.pos_shifts;
CREATE TRIGGER trg_closed_period BEFORE INSERT OR UPDATE OR DELETE ON public.pos_shifts
  FOR EACH ROW EXECUTE FUNCTION public.trg_block_closed_period();
DROP TRIGGER IF EXISTS trg_closed_period ON public.pos_wallet_transfers;
CREATE TRIGGER trg_closed_period BEFORE INSERT OR UPDATE OR DELETE ON public.pos_wallet_transfers
  FOR EACH ROW EXECUTE FUNCTION public.trg_block_closed_period();
DROP TRIGGER IF EXISTS trg_closed_period ON public.pos_manual_transfers;
CREATE TRIGGER trg_closed_period BEFORE INSERT OR UPDATE OR DELETE ON public.pos_manual_transfers
  FOR EACH ROW EXECUTE FUNCTION public.trg_block_closed_period();
DROP TRIGGER IF EXISTS trg_closed_period ON public.pos_branch_opening;
CREATE TRIGGER trg_closed_period BEFORE INSERT OR UPDATE OR DELETE ON public.pos_branch_opening
  FOR EACH ROW EXECUTE FUNCTION public.trg_block_closed_period();

COMMIT;
