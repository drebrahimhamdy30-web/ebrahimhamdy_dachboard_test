-- ═══════════════════════════════════════════════════════════════════
-- مرتجعات التعاقد: 3 حالات بدل «مربوط / مش مربوط»
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن في 2026-09-14؛ الملف ده لسيرفر التست.)
--
--   • قيد الانتظار : مفيش صف في contract_return_matches — الافتراضي
--   • مقابل فاتورة : صف ومعاه فاتورة البيع المقابلة
--   • رصيد         : صف من غير فاتورة — المرتجع اتحسب رصيد للعميل
--
-- ⚠️ الصفوف الموجودة كلها معاها فاتورة، فالـDEFAULT 'مقابل فاتورة'
--    بيصنّفها صح من غير أي تدخّل.
-- ⚠️ قيد بيمنع حالة متناقضة: «مقابل فاتورة» من غير رقم فاتورة.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.contract_return_matches
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'مقابل فاتورة';

UPDATE public.contract_return_matches
   SET status = 'مقابل فاتورة'
 WHERE status IS NULL OR btrim(status) = '';

ALTER TABLE public.contract_return_matches DROP CONSTRAINT IF EXISTS crm_status_chk;
ALTER TABLE public.contract_return_matches ADD CONSTRAINT crm_status_chk
  CHECK (status IN ('مقابل فاتورة', 'رصيد'));

ALTER TABLE public.contract_return_matches DROP CONSTRAINT IF EXISTS crm_invoice_required_chk;
ALTER TABLE public.contract_return_matches ADD CONSTRAINT crm_invoice_required_chk
  CHECK (status <> 'مقابل فاتورة' OR invoice_bill_no IS NOT NULL);

-- ⚠️ تغيير شكل الإرجاع بيحتاج DROP — والدالة SECURITY DEFINER فلازم
--    نرجّع الصلاحيات بعدها، وإلا الشاشة هترجع 401/403.
DROP FUNCTION IF EXISTS public.get_contract_returns(text);

CREATE FUNCTION public.get_contract_returns(p_branch text DEFAULT NULL::text)
 RETURNS TABLE(return_bill_no text, return_branch text, return_date timestamp with time zone,
               cust_code text, cust_name text, total_value numeric, items_count integer,
               matched_invoice_bill_no text, matched_at timestamp with time zone, matched_by text,
               match_status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH rb AS (
    SELECT r.bill_no, r.branch,
      max(r.return_date) rdate, max(r.cust_code) ccode, max(r.cust_name) cname,
      sum(r.return_value) tval, count(*) icount
    FROM returns_log r
    WHERE EXISTS (SELECT 1 FROM contract_invoices ci WHERE ci.bill_no = r.bill_no)
      AND (p_branch IS NULL OR p_branch = '' OR r.branch = p_branch)
    GROUP BY r.bill_no, r.branch
  )
  SELECT rb.bill_no, rb.branch, rb.rdate, rb.ccode, rb.cname,
    round(rb.tval::numeric,2), rb.icount::int,
    m.invoice_bill_no, m.matched_at, m.matched_by,
    coalesce(m.status, 'قيد الانتظار')          -- مفيش صف = لسه قيد الانتظار
  FROM rb
  LEFT JOIN contract_return_matches m
    ON m.return_bill_no = rb.bill_no AND coalesce(m.return_branch,'') = coalesce(rb.branch,'')
  ORDER BY (m.return_bill_no IS NOT NULL), rb.rdate DESC;   -- قيد الانتظار الأول
$function$;

REVOKE ALL ON FUNCTION public.get_contract_returns(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_contract_returns(text) TO authenticated;

COMMIT;

-- ── فحص ────────────────────────────────────────────────────────────
-- select match_status, count(*) from public.get_contract_returns('')
--  group by match_status order by 2 desc;
-- (على البرودكشن طلعت: 447 قيد الانتظار · 3 مقابل فاتورة)
