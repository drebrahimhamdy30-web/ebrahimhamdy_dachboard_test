-- ═══════════════════════════════════════════════════════════════════
-- فواتير التعاقد: ربط الفاتورة بمرتجع (أو أكتر) من شاشة الفواتير
-- ═══════════════════════════════════════════════════════════════════
-- الربط كان في اتجاه واحد بس: من المرتجع تختار الفاتورة. دلوقتي كمان
-- من الفاتورة تختار المرتجع/المرتجعات.
--
--   • suggest_contract_returns: مرتجعات التعاقد مرتّبة بالأقرب للفاتورة
--     (نفس العميل الأول، وبعدين الأقرب في الوقت). بترجّع كمان المرتجع
--     مربوط بفاتورة تانية ولا لأ عشان الشاشة تحذّر قبل ما تفك الربط.
--   • match_contract_return: اتصلّح فيها فخ — أول مرتجع بيتربط بيغيّر
--     حالة الفاتورة لـ«مقابل مرتجع»، فالمرتجع التاني كان بيسجّل الحالة
--     السابقة = «مقابل مرتجع»، وساعتها فك الربط مايرجّعش الحالة الأصلية.
--     دلوقتي بياخد الحالة السابقة من أول ربط للفاتورة نفسها.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.suggest_contract_returns(
  p_cust_code text,
  p_cust_name text,
  p_bill_date timestamptz,
  p_bill_value numeric,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 50
) RETURNS TABLE(
  return_bill_no text, return_branch text, return_date timestamptz,
  cust_code text, cust_name text, total_value numeric, items_count integer,
  matched_invoice_bill_no text, same_customer boolean,
  hours_diff numeric, val_diff numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  WITH rb AS (
    SELECT r.bill_no, r.branch,
           max(r.return_date) rdate, max(r.cust_code) ccode, max(r.cust_name) cname,
           sum(r.return_value) tval, count(*) icount
      FROM returns_log r
     WHERE EXISTS (SELECT 1 FROM contract_invoices ci WHERE ci.bill_no = r.bill_no)
     GROUP BY r.bill_no, r.branch
  )
  SELECT rb.bill_no, rb.branch, rb.rdate, rb.ccode, rb.cname,
         round(rb.tval::numeric, 2), rb.icount::int,
         m.invoice_bill_no,
         (p_cust_code IS NOT NULL AND p_cust_code <> '' AND rb.ccode = p_cust_code) AS same_customer,
         round((abs(extract(epoch FROM (rb.rdate - p_bill_date)) / 3600.0))::numeric, 1) AS hours_diff,
         round((abs(coalesce(rb.tval, 0) - coalesce(p_bill_value, 0)))::numeric, 2) AS val_diff
    FROM rb
    LEFT JOIN contract_return_matches m
      ON m.return_bill_no = rb.bill_no AND coalesce(m.return_branch, '') = coalesce(rb.branch, '')
   WHERE (p_search IS NULL OR p_search = ''
          OR rb.bill_no ILIKE '%' || p_search || '%'
          OR coalesce(rb.cname, '') ILIKE '%' || p_search || '%'
          OR coalesce(rb.ccode, '') ILIKE '%' || p_search || '%')
   ORDER BY
     -- ① نفس العميل الأول  ② بعدين الأقرب في الوقت
     (p_cust_code IS NOT NULL AND p_cust_code <> '' AND rb.ccode = p_cust_code) DESC,
     abs(extract(epoch FROM (rb.rdate - p_bill_date))) ASC,
     rb.rdate DESC
   LIMIT greatest(1, least(p_limit, 100));
$fn$;

GRANT EXECUTE ON FUNCTION public.suggest_contract_returns(text,text,timestamptz,numeric,text,integer) TO anon, authenticated;

-- ═══ إصلاح الحالة السابقة مع أكتر من مرتجع لنفس الفاتورة ═══
CREATE OR REPLACE FUNCTION public.match_contract_return(p_return_bill_no text, p_return_branch text, p_invoice_id bigint, p_return_value numeric, p_user text)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_inv contract_invoices%ROWTYPE; v_old_inv bigint; v_old_prev text; v_prev text;
BEGIN
  SELECT * INTO v_inv FROM contract_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة غير موجودة'); END IF;
  -- لو فيه ربط قديم لنفس المرتجع بفاتورة مختلفة، رجّع حالتها الأصلية
  SELECT invoice_id, invoice_prev_state INTO v_old_inv, v_old_prev FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no AND coalesce(return_branch,'') = coalesce(p_return_branch,'');
  IF v_old_inv IS NOT NULL AND v_old_inv <> p_invoice_id THEN
    UPDATE contract_invoices SET bill_state = coalesce(nullif(v_old_prev,''),'فاتورة') WHERE id = v_old_inv;
  END IF;

  -- ⚠️ الحالة السابقة: لو الفاتورة بقت «مقابل مرتجع» من ربط قبل كده،
  --    ناخد الحالة السابقة المسجّلة في أول ربط ليها مش الحالة الحالية —
  --    من غير كده فك الربط مايرجّعش حالتها الأصلية.
  v_prev := v_inv.bill_state;
  IF btrim(coalesce(v_prev,'')) = 'مقابل مرتجع' THEN
    SELECT invoice_prev_state INTO v_prev FROM contract_return_matches
     WHERE invoice_id = p_invoice_id
       AND (return_bill_no <> p_return_bill_no OR coalesce(return_branch,'') <> coalesce(p_return_branch,''))
       AND coalesce(btrim(invoice_prev_state),'') <> 'مقابل مرتجع'
     ORDER BY matched_at ASC LIMIT 1;
    v_prev := coalesce(nullif(btrim(coalesce(v_prev,'')),''), 'فاتورة');
  END IF;

  INSERT INTO contract_return_matches(return_bill_no, return_branch, invoice_id, invoice_bill_no, invoice_prev_state, return_value, matched_by)
  VALUES (p_return_bill_no, p_return_branch, p_invoice_id, v_inv.bill_no, v_prev, p_return_value, p_user)
  ON CONFLICT (return_bill_no, coalesce(return_branch,'')) DO UPDATE
    SET invoice_id = excluded.invoice_id, invoice_bill_no = excluded.invoice_bill_no,
        invoice_prev_state = excluded.invoice_prev_state, return_value = excluded.return_value,
        matched_by = excluded.matched_by, matched_at = now();
  UPDATE contract_invoices SET bill_state = 'مقابل مرتجع' WHERE id = p_invoice_id;
  RETURN jsonb_build_object('success', true, 'invoice_bill_no', v_inv.bill_no);
END $function$;

COMMIT;
