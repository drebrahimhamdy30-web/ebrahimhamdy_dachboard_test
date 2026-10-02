-- ═══════════════════════════════════════════════════════════════════
-- مبيعات الماكينات: مراجعة المحاسب (علامة + ملاحظة) + فتح الشاشة بالصلاحيات
-- ═══════════════════════════════════════════════════════════════════
-- المحاسب محتاج يعلّم «راجعت المعاملة وسليمة» ويكتب ملاحظة لو لزم.
--
-- ⚠️ ليه عمود جديد مش `reviewed` الموجود؟
--    `wallet.reviewed` محجوز بمعنى تاني: شاشة «استيراد جدول الماكينات»
--    بتعلّمه لما المعاملة تتربط بصف مستورد (1,205 صف متعلّم كده دلوقتي).
--    لو استعملناه للمراجعة هيختلط الحالتين ومش هنعرف بعد كده مين علّم
--    إيه ولا نبني تقرير صح على أي منهم.
--
-- الكتابة عبر دالة محروسة مش PATCH مباشر: اسم المُراجِع بيتاخد من
-- التوكن نفسه (مش من المتصفح) عشان «مين راجع» يبقى موثوق.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.wallet
  ADD COLUMN IF NOT EXISTS acc_reviewed    boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS acc_reviewed_by text,
  ADD COLUMN IF NOT EXISTS acc_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS acc_note        text;

COMMENT ON COLUMN public.wallet.acc_reviewed IS
  'المحاسب راجع المعاملة وأقرّ إنها سليمة — غير reviewed بتاعة الاستيراد';

CREATE INDEX IF NOT EXISTS idx_wallet_acc_reviewed ON public.wallet (acc_reviewed);

-- ═══ تعليم المراجعة / الملاحظة ═══
--   p_reviewed = null → ماتلمسش العلامة (تحديث الملاحظة بس)
--   p_note     = null → ماتلمسش الملاحظة
CREATE OR REPLACE FUNCTION public.wallet_set_review(
  p_id bigint, p_reviewed boolean DEFAULT NULL, p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_by   text  := btrim(coalesce(claims ->> 'full_name',
                                 claims -> 'app_metadata' ->> 'full_name', ''));
  r wallet%ROWTYPE;
BEGIN
  PERFORM public.require_app_role(array['admin','accountant']);
  IF v_by = '' THEN v_by := 'مستخدم'; END IF;

  UPDATE wallet SET
    acc_reviewed    = coalesce(p_reviewed, acc_reviewed),
    acc_reviewed_by = CASE WHEN p_reviewed IS NULL THEN acc_reviewed_by
                           WHEN p_reviewed THEN v_by ELSE NULL END,
    acc_reviewed_at = CASE WHEN p_reviewed IS NULL THEN acc_reviewed_at
                           WHEN p_reviewed THEN now() ELSE NULL END,
    acc_note        = CASE WHEN p_note IS NULL THEN acc_note
                           ELSE nullif(btrim(p_note), '') END
  WHERE id = p_id
  RETURNING * INTO r;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'المعاملة غير موجودة');
  END IF;
  RETURN jsonb_build_object('success', true, 'id', r.id,
                            'acc_reviewed', r.acc_reviewed,
                            'acc_reviewed_by', r.acc_reviewed_by,
                            'acc_reviewed_at', r.acc_reviewed_at,
                            'acc_note', r.acc_note);
END $fn$;

GRANT EXECUTE ON FUNCTION public.wallet_set_review(bigint, boolean, text) TO authenticated;

COMMIT;
