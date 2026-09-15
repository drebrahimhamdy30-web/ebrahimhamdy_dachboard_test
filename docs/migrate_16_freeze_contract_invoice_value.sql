-- ═══════════════════════════════════════════════════════════════════
-- تجميد قيمة فاتورة التعاقد بعد أول أكشن من المحاسب + ترجيع اللي فات
-- ═══════════════════════════════════════════════════════════════════
-- المشكلة:
--   المزامنة الليلية (n8n، بتتصل بالقاعدة مباشرة كـ postgres) بتعمل
--   upsert على contract_invoices وبتكتب `total_bill` من جديد من eplus.
--   و eplus بينقّص إجمالي الفاتورة لما يتعمل عليها مرتجع. فالنتيجة إن
--   قيمة فاتورة المحاسب راجعها وقفل عليها بتتغيّر من ورا ظهره.
--
--   مثال موثّق: فاتورة 1453326 (المعمورة) — 3 بنود × 198 = 594،
--   اتراجعت 2026-09-03 01:45، وبعدها بيوم اتعمل عليها مرتجع 198 على
--   صنف «له ادويه بقيمة»، فالسحبة اللي بعدها كتبتها 396.
--
--   ونفس السبب كان بيمسح **الدمج**: المحاسب يدمج فاتورة في فاتورة
--   فالقيمة تبقى A+B، وأول سحبة بعدها ترجّعها لقيمة eplus وتضيّع الدمج.
--
-- الحل:
--   (1) تريجر بيمنع أي جهة غير الشاشة من تغيير القيمة بعد ما
--       reviewed_at يتسجّل (= المحاسب خد أكشن).
--   (2) ترجيع الفواتير اللي القيمة اتغيّرت فيها غلط.
--
-- التمييز بين الشاشة والمزامنة:
--   PostgREST بيعمل SET ROLE authenticated → current_user='authenticated'
--   n8n بيتصل مباشرة → current_user='postgres'
--   وفيه مخرج يدوي للصيانة: SET LOCAL app.allow_total_overwrite='on'
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── سجل التصحيح: أي تعديل على قيمة بنعمله هنا يتسجّل قبل وبعد ──────
CREATE TABLE IF NOT EXISTS public.contract_invoice_value_fixes (
  id              bigserial PRIMARY KEY,
  invoice_id      bigint      NOT NULL,
  bill_no         text,
  branch          text,
  old_total       numeric,
  new_total       numeric,
  old_total_net   numeric,
  new_total_net   numeric,
  reason          text        NOT NULL,
  fixed_at        timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.contract_invoice_value_fixes FROM PUBLIC, anon;
GRANT SELECT ON public.contract_invoice_value_fixes TO authenticated;

-- ═══ (1) ترجيع اللي فات ════════════════════════════════════════════
-- القيمة الأصلية = مجموع بنود الفاتورة في sales_items.
-- اتأكدت إنها مرجع سليم: في 720 فاتورة متراجَعة من غير مرتجعات،
-- total_bill = مجموع البنود بالظبط (39 استثناء بفروق تقريب اتساب).
--
-- حالتين بس بنصلّحهم — وكل واحدة ليها هدف مختلف:
--   أ) «مرتجع بعد المراجعة»: المحاسب راجعها وهي بقيمتها الكاملة،
--      وبعدين نزل مرتجع ونقّصها → ترجع لمجموع البنود.
--   ب) «دمج اتمسح»: قيمتها أقل من (أساسها + الفواتير المدموجة فيها)
--      → ترجع لـ (القيمة الحالية + بنود الفواتير الأبناء).
-- ما بنلمسش الفواتير اللي المرتجع فيها نزل **قبل** المراجعة — دي
-- المحاسب شافها بقيمتها المنقوصة أصلاً وده اللي المفروض يتجمّد.
WITH l AS (
  SELECT bill_no, sum(line_total)::numeric ls FROM public.sales_items GROUP BY 1
), r AS (
  SELECT bill_no, sum(return_value)::numeric rv, max(return_date) rd
    FROM public.returns_log GROUP BY 1
), b AS (
  SELECT ci.id, ci.bill_no, ci.branch, ci.reviewed_at,
         ci.total_bill::numeric cur, ci.total_bill_net::numeric cur_net,
         l.ls own_lines, coalesce(r.rv,0) rv, r.rd,
         (SELECT coalesce(sum(coalesce(cl.ls, c2.total_bill::numeric, 0)),0)
            FROM public.contract_invoices c2
            LEFT JOIN l cl ON cl.bill_no = c2.bill_no
           WHERE c2.merged_into = ci.bill_no) kids,
         (SELECT count(*) FROM public.contract_invoices c2
           WHERE c2.merged_into = ci.bill_no) nkids
    FROM public.contract_invoices ci
    LEFT JOIN l ON l.bill_no = ci.bill_no
    LEFT JOIN r ON r.bill_no = ci.bill_no
   WHERE ci.reviewed_at IS NOT NULL AND l.ls IS NOT NULL
), c AS (
  SELECT b.*,
    (rv > 0
      AND abs(coalesce(cur,-1) - (own_lines - rv)) < 0.05
      AND cur IS DISTINCT FROM own_lines
      AND rd > (reviewed_at AT TIME ZONE 'Africa/Cairo'))          AS ret_after,
    (nkids > 0 AND coalesce(cur,0) < kids + own_lines - rv - 0.05) AS wiped
  FROM b
), t AS (
  SELECT c.*,
         CASE WHEN ret_after THEN own_lines ELSE cur + kids END AS target,
         CASE WHEN ret_after THEN 'مرتجع بعد المراجعة' ELSE 'دمج اتمسح' END AS reason
    FROM c WHERE ret_after OR wiped
), upd AS (
  UPDATE public.contract_invoices ci
     SET total_bill = t.target,
         -- الصافي مش معروض في أي شاشة، بنظبّطه بنفس النسبة لما ينفع بس
         total_bill_net = CASE
           WHEN t.cur_net IS NULL OR t.cur IS NULL OR t.cur = 0 THEN ci.total_bill_net
           ELSE round(t.cur_net * t.target / t.cur, 3) END
    FROM t WHERE ci.id = t.id AND ci.total_bill::numeric IS DISTINCT FROM t.target
  RETURNING ci.id, ci.bill_no, ci.branch, ci.total_bill, ci.total_bill_net,
            t.cur, t.cur_net, t.reason
)
INSERT INTO public.contract_invoice_value_fixes
  (invoice_id, bill_no, branch, old_total, new_total, old_total_net, new_total_net, reason)
SELECT id, bill_no, branch, cur, total_bill, cur_net, total_bill_net, reason FROM upd;

-- ── الفواتير اللي قيمتها الحقيقية صفر وبقت NULL ─────────────────────
-- سببها الشاشة: `item.total_bill || null` في quickUpdateBillState وإخواتها
-- بتحوّل الصفر لـNULL. اتأكدت إن الـ29 صف كلهم قيمتهم الحقيقية صفر.
-- (الإصلاح في الجافاسكريبت بردو — `?? null` بدل `|| null`.)
UPDATE public.contract_invoices SET total_bill = 0
 WHERE total_bill IS NULL AND reviewed_at IS NOT NULL;

-- ═══ (2) التجميد للمستقبل ══════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.ci_freeze_reviewed_total()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- الشاشة (authenticated) مسموح لها تغيّر القيمة — الدمج والتعديل اليدوي.
  -- أي جهة تانية (المزامنة كـpostgres) ممنوعة بعد ما المحاسب خد أكشن.
  IF OLD.reviewed_at IS NOT NULL
     AND current_user <> 'authenticated'
     AND coalesce(current_setting('app.allow_total_overwrite', true), '') <> 'on'
  THEN
    NEW.total_bill     := OLD.total_bill;
    NEW.total_bill_net := OLD.total_bill_net;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_ci_freeze_reviewed_total ON public.contract_invoices;
CREATE TRIGGER trg_ci_freeze_reviewed_total
  BEFORE UPDATE ON public.contract_invoices
  FOR EACH ROW EXECUTE FUNCTION public.ci_freeze_reviewed_total();

COMMIT;

-- ── فحص ────────────────────────────────────────────────────────────
-- select reason, count(*), sum(new_total-old_total) from contract_invoice_value_fixes group by 1;
-- (على البرودكشن 2026-09-15: «مرتجع بعد المراجعة» 26 · «دمج اتمسح» 21)
--
-- اختبار التجميد (لازم القيمة ما تتغيرش):
--   update contract_invoices set total_bill = 1 where bill_no='1453326';
--   select total_bill from contract_invoices where bill_no='1453326';  -- 594
