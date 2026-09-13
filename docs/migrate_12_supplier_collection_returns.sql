-- ═══════════════════════════════════════════════════════════════════
-- أسطر مرتجعات المورد الآجل — تكملة لـmigrate_10
-- ═══════════════════════════════════════════════════════════════════
-- شغّله بعد migrate_10_supplier_collections.sql.
-- (اتطبّق على البرودكشن بالفعل في 2026-09-13؛ الملف ده لسيرفر التست.)
--
-- الأسطر للنوعين (كاش وآجل): رقم الفاتورة هنا هو الفاتورة اللي الصنف
-- **جه عليها** — ودي معروفة في الحالتين. اللي مش معروف في الكاش هو
-- الفاتورة **الجاية** اللي المرتجع هيتخصم منها، وعشان كده الكاش مالوش
-- invoices_total ولا net_total. ده الفرق الوحيد بين النوعين.
--
-- ⚠️ إجمالي مرتجعات المورد **مابيتبعتش من المتصفح** — تريجر بيحسبه من
--    الأسطر. وnet_total (عمود GENERATED) بيتحدّث معاه تلقائيًا. يعني
--    مستحيل يبقى فيه مورد إجمالي مرتجعاته مايساويش مجموع أسطره.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.supplier_collection_returns (
  id             bigserial PRIMARY KEY,
  collection_id  bigint NOT NULL REFERENCES public.supplier_collections(id) ON DELETE CASCADE,
  kind           text   NOT NULL,
  item_name      text   NOT NULL,
  qty            numeric(12,2) NOT NULL,
  unit_value     numeric(14,2) NOT NULL,
  line_total     numeric(14,2) GENERATED ALWAYS AS (qty * unit_value) STORED,
  invoice_no     text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT scr_kind_chk   CHECK (kind IN ('مرتجع', 'لم يصل')),
  CONSTRAINT scr_amount_chk CHECK (qty > 0 AND unit_value >= 0)
);

CREATE INDEX IF NOT EXISTS scr_collection_idx ON public.supplier_collection_returns (collection_id);
CREATE INDEX IF NOT EXISTS scr_invoice_idx    ON public.supplier_collection_returns (invoice_no);

CREATE OR REPLACE FUNCTION public.sync_collection_returns_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE cid bigint;
BEGIN
  cid := COALESCE(NEW.collection_id, OLD.collection_id);
  UPDATE public.supplier_collections c
     SET returns_total = COALESCE((SELECT SUM(r.line_total)
                                     FROM public.supplier_collection_returns r
                                    WHERE r.collection_id = cid), 0)
   WHERE c.id = cid;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_collection_returns ON public.supplier_collection_returns;
CREATE TRIGGER trg_sync_collection_returns
AFTER INSERT OR UPDATE OR DELETE ON public.supplier_collection_returns
FOR EACH ROW EXECUTE FUNCTION public.sync_collection_returns_total();

REVOKE ALL ON public.supplier_collection_returns FROM anon;
REVOKE ALL ON SEQUENCE public.supplier_collection_returns_id_seq FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.supplier_collection_returns TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.supplier_collection_returns_id_seq TO authenticated;

ALTER TABLE public.supplier_collection_returns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS scr_authenticated ON public.supplier_collection_returns;
CREATE POLICY scr_authenticated ON public.supplier_collection_returns
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

COMMIT;

-- ── فحص بعد التشغيل (بيمسح نفسه) ──────────────────────────────────
-- with c as (insert into supplier_collections
--   (batch_id,branch,supplier_name,supplier_type,invoices_total,returns_total,created_by)
--   values (gen_random_uuid(),'__TEST__','مورد','آجل',100000,0,'test') returning id)
-- insert into supplier_collection_returns (collection_id,kind,item_name,qty,unit_value,invoice_no)
-- select c.id,'مرتجع','صنف',10,250,'INV-1' from c;
-- select returns_total, net_total from supplier_collections where branch='__TEST__';  -- 2500 / 97500
-- delete from supplier_collections where branch='__TEST__';
