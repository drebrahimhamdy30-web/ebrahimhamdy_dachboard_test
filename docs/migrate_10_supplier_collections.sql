-- ═══════════════════════════════════════════════════════════════════
-- جدول «تحصيلات الشركات» — قسم جديد في شاشة «طلب جديد»
-- ═══════════════════════════════════════════════════════════════════
-- شغّله على السيرفر (supabase.ebrahimhamdy.com) مرة واحدة.
-- القسم في الشاشة مش هيشتغل قبل ما تشغّله — هيقول «الجدول لسه ماتعملش».
--
-- المراجع بيراجع لكل الفروع، فبيختار الفرع مع كل حفظة، وبيضيف مورد ورا
-- التاني في نفس الجلسة. كل حفظة سطورها بتاخد نفس batch_id عشان نعرف
-- اللي اتحفظ مع بعض.
--
-- نوعان من الموردين — والفرق مش في الخصم بس، ده في **إيه اللي بنسجّله**:
--   • آجل : المرتجعات بتتخصم من فواتير **استلمناها** — فقيمتها معروفة،
--           بنسجّل الفواتير + المرتجعات، والصافي = الفرق.
--   • كاش : المرتجعات بتتخصم من **الفاتورة الجاية** — ودي لسه قيمتها
--           **مش معروفة**، فبنسجّل المرتجعات والملاحظات بس.
--
-- ⚠️ عشان كده invoices_total بيقبل NULL: الـNULL هنا معناها «لسه مش
--    معروفة» وهي حاجة تانية خالص عن صفر (يعني مفيش فواتير). ولإن
--    net_total = invoices − returns، الصافي بيطلع NULL تلقائيًا للكاش —
--    وده الصح: مينفعش نحسب صافي من رقم مش معروف.
--
-- الجدول بيسجّل النوع؛ الخصم الفعلي قرار محاسبي برّه الشاشة.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.supplier_collections (
  id              bigserial PRIMARY KEY,
  batch_id        uuid        NOT NULL,
  branch          text        NOT NULL,
  supplier_code   text,                      -- كود المورد من لقطة الأرصدة لو اتاخد من القايمة
  supplier_name   text        NOT NULL,
  supplier_type   text        NOT NULL,
  invoices_total  numeric(14,2),             -- NULL = لسه مش معروفة (كاش)
  returns_total   numeric(14,2) NOT NULL DEFAULT 0,
  -- الصافي **محسوب في القاعدة** مش مبعوت من المتصفح: كده مستحيل يتخزّن
  -- صافي مايساويش الفرق. وبيبقى NULL لو الفواتير مش معروفة.
  net_total       numeric(14,2) GENERATED ALWAYS AS (invoices_total - returns_total) STORED,
  notes           text,                      -- ملاحظات المورد ده (مش الحفظة كلها)
  created_by      text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT supplier_collections_type_chk
    CHECK (supplier_type IN ('كاش', 'آجل')),
  CONSTRAINT supplier_collections_amounts_chk
    CHECK ((invoices_total IS NULL OR invoices_total >= 0) AND returns_total >= 0),
  -- الآجل لازم له قيمة فواتير — دي فواتير مستلمة فقيمتها معروفة
  CONSTRAINT supplier_collections_credit_needs_invoice_chk
    CHECK (supplier_type <> 'آجل' OR invoices_total IS NOT NULL)
);

-- ── لو الجدول اتعمل قبل كده بالنسخة الأولى (invoices_total NOT NULL) ──
-- الكتلة دي بتصلّحه من غير ما تفقد بيانات. مالهاش أي أثر لو الجدول
-- لسه متعمل دلوقتي بالتعريف اللي فوق.
ALTER TABLE public.supplier_collections ALTER COLUMN invoices_total DROP NOT NULL;
ALTER TABLE public.supplier_collections ALTER COLUMN invoices_total DROP DEFAULT;
ALTER TABLE public.supplier_collections DROP CONSTRAINT IF EXISTS supplier_collections_amounts_chk;
ALTER TABLE public.supplier_collections ADD  CONSTRAINT supplier_collections_amounts_chk
  CHECK ((invoices_total IS NULL OR invoices_total >= 0) AND returns_total >= 0);
ALTER TABLE public.supplier_collections DROP CONSTRAINT IF EXISTS supplier_collections_credit_needs_invoice_chk;
ALTER TABLE public.supplier_collections ADD  CONSTRAINT supplier_collections_credit_needs_invoice_chk
  CHECK (supplier_type <> 'آجل' OR invoices_total IS NOT NULL);

CREATE INDEX IF NOT EXISTS supplier_collections_branch_idx    ON public.supplier_collections (branch);
CREATE INDEX IF NOT EXISTS supplier_collections_created_idx   ON public.supplier_collections (created_at DESC);
CREATE INDEX IF NOT EXISTS supplier_collections_batch_idx     ON public.supplier_collections (batch_id);
CREATE INDEX IF NOT EXISTS supplier_collections_supplier_idx  ON public.supplier_collections (supplier_name);

-- ── الصلاحيات: طبقتين منفصلتين زي باقي الجداول بعد إغلاق anon ──────
-- GRANT هو اللي بيحمي لو سياسة اتضافت بالغلط بعدين، فمش بنكتفي بالسياسة.
REVOKE ALL ON public.supplier_collections FROM anon;
REVOKE ALL ON SEQUENCE public.supplier_collections_id_seq FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.supplier_collections TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.supplier_collections_id_seq TO authenticated;

ALTER TABLE public.supplier_collections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS supplier_collections_authenticated ON public.supplier_collections;
CREATE POLICY supplier_collections_authenticated
  ON public.supplier_collections
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

COMMIT;

-- ── فحص بعد التشغيل ────────────────────────────────────────────────
-- SELECT column_name, data_type, is_generated
--   FROM information_schema.columns
--  WHERE table_name = 'supplier_collections' ORDER BY ordinal_position;
--
-- انتبه: PostgREST بيكاش الـschema. لو الجدول ماظهرش للشاشة بعد التشغيل:
--   NOTIFY pgrst, 'reload schema';
