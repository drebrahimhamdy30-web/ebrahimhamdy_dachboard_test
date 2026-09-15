-- ═══════════════════════════════════════════════════════════════════
-- دمج فواتير التعاقد: عملية واحدة + قابلة للفك
-- ═══════════════════════════════════════════════════════════════════
-- كان قبل كده: الشاشة بتبعت PATCH على الأب وPATCH تاني على الابن،
-- من غير ترانزاكشن. لو التاني فشل: قيمة الأب بقت A+B والابن لسه
-- فاتورة عادية تقدر تدخل مطالبة = ازدواج. وبما إن الشاشة بتقول «فشل
-- الدمج»، المحاسب بيعيد المحاولة والابن لسه في قايمة المرشحين،
-- فالأب بتزيد بـB تاني. (مفيش حالة حصلت فعلًا لحد 2026-09-15،
-- بس مفيش حاجة كانت بتمنعها.)
--
-- وكمان: مكانش فيه أي طريقة لفك الدمج غير التعديل اليدوي للصفين.
--
-- الجديد:
--   merge_contract_invoices()   — الاتنين في ترانزاكشن واحدة + تحقّقات
--   unmerge_contract_invoice()  — بترجّع القيمة وتفكّ الابن
--   contract_merge_log          — سجل بيخلي الفك ممكن ودقيق
--
-- ⚠️ الدالتين SECURITY DEFINER، يعني جوّاهم current_user='postgres'،
--    فتريجر التجميد (migrate_16) كان هيمنعهم من تغيير القيمة —
--    عشان كده بيرفعوا app.allow_total_overwrite محليًا.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.contract_merge_log (
  id                  bigserial PRIMARY KEY,
  parent_id           bigint      NOT NULL,
  parent_bill_no      text,
  child_id            bigint      NOT NULL,
  child_bill_no       text,
  branch              text,
  added_value         numeric     NOT NULL DEFAULT 0,  -- اللي اتضاف على الأب
  parent_total_before numeric,
  child_prev_state    text,
  merged_by           text,
  merged_at           timestamptz NOT NULL DEFAULT now(),
  is_legacy           boolean     NOT NULL DEFAULT false,
  undone_at           timestamptz,
  undone_by           text
);

-- ابن واحد مايكونش مدموج في أكتر من مكان في نفس الوقت
CREATE UNIQUE INDEX IF NOT EXISTS ux_cml_open_child
  ON public.contract_merge_log(child_id) WHERE undone_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_cml_parent ON public.contract_merge_log(parent_id);

REVOKE ALL ON public.contract_merge_log FROM PUBLIC, anon;
GRANT SELECT ON public.contract_merge_log TO authenticated;

-- ── تسجيل الدمجات القديمة عشان تبقى قابلة للفك هي كمان ─────────────
-- قيمة الابن = total_bill بتاعه، ولو صفر نرجع لمجموع بنوده.
-- المبلغ ده بيتعرض للمحاسب في تأكيد الفك قبل ما ينفّذ.
INSERT INTO public.contract_merge_log
  (parent_id, parent_bill_no, child_id, child_bill_no, branch,
   added_value, parent_total_before, child_prev_state, merged_by, merged_at, is_legacy)
SELECT p.id, p.bill_no, c.id, c.bill_no, c.branch,
       coalesce(nullif(c.total_bill, 0),
                (SELECT sum(s.line_total) FROM public.sales_items s WHERE s.bill_no = c.bill_no),
                0),
       NULL, 'فاتورة', c.reviewed_by, coalesce(c.reviewed_at, c.created_at), true
  FROM public.contract_invoices c
  JOIN public.contract_invoices p
    ON p.bill_no = c.merged_into AND coalesce(p.branch,'') = coalesce(c.branch,'')
 WHERE c.bill_state = 'مدموجة'
   AND NOT EXISTS (SELECT 1 FROM public.contract_merge_log m
                    WHERE m.child_id = c.id AND m.undone_at IS NULL);

-- ═══ الدمج ═════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.merge_contract_invoices(
  p_parent_id bigint, p_child_id bigint, p_user text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE a contract_invoices%ROWTYPE; b contract_invoices%ROWTYPE;
        v_add numeric; v_stamp timestamptz := now(); v_new numeric;
        v_claimed boolean;
BEGIN
  IF p_parent_id IS NULL OR p_child_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'فاتورة ناقصة'); END IF;
  IF p_parent_id = p_child_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'مينفعش تدمج الفاتورة في نفسها'); END IF;

  -- القفل بترتيب الـid ثابت عشان مايحصلش deadlock لو اتنين بيدمجوا مع بعض
  PERFORM 1 FROM contract_invoices
   WHERE id IN (p_parent_id, p_child_id) ORDER BY id FOR UPDATE;

  SELECT * INTO a FROM contract_invoices WHERE id = p_parent_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة الأساسية مش موجودة'); END IF;
  SELECT * INTO b FROM contract_invoices WHERE id = p_child_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة المراد دمجها مش موجودة'); END IF;

  IF coalesce(a.branch,'') <> coalesce(b.branch,'') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'الفاتورتين من فرعين مختلفين (' || coalesce(a.branch,'—') || ' / ' || coalesce(b.branch,'—') || ')'); END IF;

  IF btrim(coalesce(a.cust_code,'')) = '' OR btrim(coalesce(a.cust_code,'')) <> btrim(coalesce(b.cust_code,'')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'كود العميل مختلف'); END IF;

  IF b.bill_state = 'مدموجة' THEN
    RETURN jsonb_build_object('success', false, 'error', 'الفاتورة دي مدموجة بالفعل'); END IF;
  IF a.bill_state = 'مدموجة' THEN
    RETURN jsonb_build_object('success', false, 'error', 'مينفعش تدمج في فاتورة مدموجة'); END IF;

  v_claimed := b.claim_id IS NOT NULL AND btrim(b.claim_id) NOT IN ('', '0', 'null');
  IF v_claimed THEN
    RETURN jsonb_build_object('success', false, 'error', 'الفاتورة المراد دمجها داخلة مطالبة بالفعل'); END IF;

  v_add := coalesce(b.total_bill, 0);
  v_new := coalesce(a.total_bill, 0) + v_add;

  -- تخطّي تريجر التجميد: ده أكشن محاسب مقصود مش مزامنة
  PERFORM set_config('app.allow_total_overwrite', 'on', true);

  UPDATE contract_invoices
     SET total_bill = v_new, reviewed_at = v_stamp, reviewed_by = p_user
   WHERE id = a.id;
  UPDATE contract_invoices
     SET bill_state = 'مدموجة', merged_into = a.bill_no,
         reviewed_at = v_stamp, reviewed_by = p_user
   WHERE id = b.id;

  INSERT INTO contract_merge_log
    (parent_id, parent_bill_no, child_id, child_bill_no, branch,
     added_value, parent_total_before, child_prev_state, merged_by, merged_at)
  VALUES (a.id, a.bill_no, b.id, b.bill_no, a.branch,
          v_add, a.total_bill, nullif(btrim(coalesce(b.bill_state,'')),''), p_user, v_stamp);

  RETURN jsonb_build_object('success', true, 'new_total', v_new, 'added', v_add,
                            'parent_bill_no', a.bill_no, 'child_bill_no', b.bill_no,
                            'parent_in_claim', a.claim_id IS NOT NULL
                                               AND btrim(coalesce(a.claim_id,'')) NOT IN ('','0','null'));
END $fn$;

-- ═══ فك الدمج ══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.unmerge_contract_invoice(
  p_child_id bigint, p_user text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE m contract_merge_log%ROWTYPE; a contract_invoices%ROWTYPE; b contract_invoices%ROWTYPE;
        v_stamp timestamptz := now(); v_new numeric;
BEGIN
  SELECT * INTO m FROM contract_merge_log
   WHERE child_id = p_child_id AND undone_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'مفيش دمج مفتوح للفاتورة دي'); END IF;

  PERFORM 1 FROM contract_invoices
   WHERE id IN (m.parent_id, m.child_id) ORDER BY id FOR UPDATE;

  SELECT * INTO a FROM contract_invoices WHERE id = m.parent_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة الأساسية اتشالت'); END IF;
  SELECT * INTO b FROM contract_invoices WHERE id = m.child_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة المدموجة اتشالت'); END IF;

  v_new := coalesce(a.total_bill, 0) - m.added_value;
  IF v_new < -0.005 THEN
    RETURN jsonb_build_object('success', false,
      'error', 'قيمة الفاتورة الأساسية (' || coalesce(a.total_bill,0) ||
               ') أقل من اللي اتضاف (' || m.added_value || ') — محتاجة مراجعة يدوية'); END IF;

  PERFORM set_config('app.allow_total_overwrite', 'on', true);

  UPDATE contract_invoices
     SET total_bill = round(v_new, 3), reviewed_at = v_stamp, reviewed_by = p_user
   WHERE id = a.id;
  UPDATE contract_invoices
     SET bill_state = coalesce(nullif(btrim(coalesce(m.child_prev_state,'')),''), 'فاتورة'),
         merged_into = NULL, reviewed_at = v_stamp, reviewed_by = p_user
   WHERE id = b.id;

  UPDATE contract_merge_log SET undone_at = v_stamp, undone_by = p_user WHERE id = m.id;

  RETURN jsonb_build_object('success', true, 'new_total', round(v_new,3),
                            'removed', m.added_value, 'child_bill_no', b.bill_no,
                            'parent_bill_no', a.bill_no, 'was_legacy', m.is_legacy);
END $fn$;

REVOKE ALL ON FUNCTION public.merge_contract_invoices(bigint, bigint, text)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unmerge_contract_invoice(bigint, text)         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.merge_contract_invoices(bigint, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unmerge_contract_invoice(bigint, text)        TO authenticated;

COMMIT;

-- ── فحص ────────────────────────────────────────────────────────────
-- select count(*) filter (where is_legacy) legacy, count(*) all_rows,
--        count(*) filter (where added_value = 0) zero_value
--   from contract_merge_log where undone_at is null;
-- (على البرودكشن 2026-09-15: 86 كلهم legacy، 46 منهم قيمتهم صفر)
