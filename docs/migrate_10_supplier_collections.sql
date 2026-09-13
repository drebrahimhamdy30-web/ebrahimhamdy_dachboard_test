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
-- نوعان من الموردين — الفرق في **مقابل إيه** بنخصم المرتجعات:
--   • كاش : المرتجعات بتتخصم من الفاتورة الجاية
--   • آجل : المرتجعات بتتخصم من الفواتير اللي استلمناها
-- الجدول بيسجّل النوع بس؛ الخصم الفعلي قرار محاسبي برّه الشاشة.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.supplier_collections (
  id              bigserial PRIMARY KEY,
  batch_id        uuid        NOT NULL,
  branch          text        NOT NULL,
  supplier_code   text,                      -- كود المورد من لقطة الأرصدة لو اتاخد من القايمة
  supplier_name   text        NOT NULL,
  supplier_type   text        NOT NULL,
  invoices_total  numeric(14,2) NOT NULL DEFAULT 0,
  returns_total   numeric(14,2) NOT NULL DEFAULT 0,
  -- الصافي **محسوب في القاعدة** مش مبعوت من المتصفح: كده مستحيل يتخزّن
  -- صافي مايساويش الفرق، مهما حصل في الواجهة
  net_total       numeric(14,2) GENERATED ALWAYS AS (invoices_total - returns_total) STORED,
  notes           text,
  created_by      text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT supplier_collections_type_chk
    CHECK (supplier_type IN ('كاش', 'آجل')),
  CONSTRAINT supplier_collections_amounts_chk
    CHECK (invoices_total >= 0 AND returns_total >= 0)
);

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
