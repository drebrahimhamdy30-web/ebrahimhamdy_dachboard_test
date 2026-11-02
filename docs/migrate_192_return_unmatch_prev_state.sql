-- migrate_192_return_unmatch_prev_state.sql
--
-- فكّ ربط المرتجع كان بيرفّع الفاتورة لحالة «فاتورة» من غير ما حد يختارها.
--
-- الحكاية: فاتورة 1494399 (سعيد عبدالعاطي عبده، 10-23، قيمتها صفر) لقيناها
-- حالتها «فاتورة» وهي بلا نوع وبلا طريقة دفع — والحارس في الواجهة بيمنع ده.
-- اتضح إن reviewed_at/reviewed_by فاضيين، يعني الشاشة عمرها ما لمستها:
--   ١. وصلت من المزامنة «قيد الانتظار» (حالة فاضية) — وده الطبيعي
--   ٢. حد ربطها بمرتجع → «مقابل مرتجع»، واتسجّلت حالتها السابقة = فاضية (صح)
--   ٣. حد فكّ الربط → القيمة الاحتياطية 'فاتورة' رفّعتها لحالة ماكانتش فيها
--
-- وده خطير لأن الفاتورة اللي حالتها «فاتورة» وبلا نوع مابتظهرش في أي مجموعة
-- في شاشة المطالبات (التقسيم بالنوع)، ومع ذلك createClaim بتكتب عليها claim_id
-- فتختفي من المنتظرة والشركة ماتتطالبش بيها. (الحارس الواجهي اتضاف في
-- claims.html و sales_contracts.html، وده بيقفل الباب من ناحية القاعدة.)
--
-- التعرّض وقت الإصلاح: 952 رابط في contract_return_matches حالتهم السابقة
-- المحفوظة فاضية — أي واحد فيهم يتفك ربطه كان هيترفّع غلط.
--
-- التغيير: القيمة الاحتياطية تبقى «قيد الانتظار» (NULL) بدل 'فاتورة'.
-- الحالة الفاضية تفضل فاضية — ده الأمين: الفاتورة ترجع زي ما كانت بالظبط.
-- موجودة في تلات مواضع: واحد في unmatch، واتنين جوّه match.
--
-- راجع memory: safe-fallback-turns-unsafe

-- ═══ ١. فكّ الربط ═══
create or replace function public.unmatch_contract_return(
  p_return_bill_no text, p_return_branch text, p_return_day date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_inv bigint; v_prev text;
BEGIN
  SELECT invoice_id, invoice_prev_state INTO v_inv, v_prev FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no
      AND coalesce(return_branch,'') = coalesce(p_return_branch,'')
      AND return_day = p_return_day;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'مفيش ربط'); END IF;
  IF v_inv IS NOT NULL THEN
    -- كان: coalesce(nullif(v_prev,''),'فاتورة') — الفاضية بتترفّع غلط
    UPDATE contract_invoices SET bill_state = nullif(v_prev,'') WHERE id = v_inv;
  END IF;
  DELETE FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no
      AND coalesce(return_branch,'') = coalesce(p_return_branch,'')
      AND return_day = p_return_day;
  RETURN jsonb_build_object('success', true);
END $function$;

-- ═══ ٢. الربط (بيرجّع حالة فاتورة قديمة لو المرتجع اتنقل) ═══
create or replace function public.match_contract_return(
  p_return_bill_no text, p_return_branch text, p_return_day date,
  p_invoice_id bigint, p_return_value numeric, p_user text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_inv contract_invoices%ROWTYPE; v_old_inv bigint; v_old_prev text; v_prev text;
BEGIN
  IF p_return_day IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يوم المرتجع مطلوب');
  END IF;
  SELECT * INTO v_inv FROM contract_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة غير موجودة'); END IF;
  SELECT invoice_id, invoice_prev_state INTO v_old_inv, v_old_prev FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no
      AND coalesce(return_branch,'') = coalesce(p_return_branch,'')
      AND return_day = p_return_day;
  IF v_old_inv IS NOT NULL AND v_old_inv <> p_invoice_id THEN
    -- كان: coalesce(nullif(v_old_prev,''),'فاتورة')
    UPDATE contract_invoices SET bill_state = nullif(v_old_prev,'') WHERE id = v_old_inv;
  END IF;
  v_prev := v_inv.bill_state;
  IF btrim(coalesce(v_prev,'')) = 'مقابل مرتجع' THEN
    SELECT invoice_prev_state INTO v_prev FROM contract_return_matches
     WHERE invoice_id = p_invoice_id
       AND (return_bill_no <> p_return_bill_no
            OR coalesce(return_branch,'') <> coalesce(p_return_branch,'')
            OR return_day <> p_return_day)
       AND coalesce(btrim(invoice_prev_state),'') <> 'مقابل مرتجع'
     ORDER BY matched_at ASC LIMIT 1;
    -- كان: coalesce(nullif(btrim(coalesce(v_prev,'')),''), 'فاتورة')
    v_prev := nullif(btrim(coalesce(v_prev,'')),'');
  END IF;
  INSERT INTO contract_return_matches(return_bill_no, return_branch, return_day,
         invoice_id, invoice_bill_no, invoice_prev_state, return_value, matched_by)
  VALUES (p_return_bill_no, p_return_branch, p_return_day,
          p_invoice_id, v_inv.bill_no, v_prev, p_return_value, p_user)
  ON CONFLICT (return_bill_no, coalesce(return_branch,''), return_day) DO UPDATE
    SET invoice_id = excluded.invoice_id, invoice_bill_no = excluded.invoice_bill_no,
        invoice_prev_state = excluded.invoice_prev_state, return_value = excluded.return_value,
        matched_by = excluded.matched_by, matched_at = now();
  UPDATE contract_invoices SET bill_state = 'مقابل مرتجع' WHERE id = p_invoice_id;
  RETURN jsonb_build_object('success', true, 'invoice_bill_no', v_inv.bill_no);
END $function$;

notify pgrst, 'reload schema';
