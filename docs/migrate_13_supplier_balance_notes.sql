-- ═══════════════════════════════════════════════════════════════════
-- أسباب أرصدة الموردين — شاشة «متابعة أرصدة الموردين» بعد إعادة تصميمها
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن في 2026-09-13؛ الملف ده لسيرفر التست.)
--
-- الفكرة: كل مورد المفروض رصيده صفر. أي رصيد ≠ صفر بيظهر للمراجع
-- عشان يكتب سببه، وبعدها يختفي من قايمة «محتاج سبب».
--
-- ⚠️ الملاحظة متربطة **بقيمة الرصيد وقت كتابتها** (عمود balance) — ودي
--    نقطة التصميم الأساسية: لما الكشف يتسحب تاني ويطلع الرصيد اتغيّر،
--    المورد يرجع يظهر عشان يتكتب سبب جديد. القديم بيفضل محفوظ وبيتعرض
--    تحت المورد. الجدول append-only: كل سبب سطر جديد، مفيش مسح.
--
-- الهامش: أي رصيد أصغر من supplier_balance_settings.threshold (افتراضي
-- 0.01) بيتعتبر صفر ومابيظهرش — أرصدة القروش كانت هتغرق القايمة.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.supplier_balance_notes (
  id            bigserial PRIMARY KEY,
  branch        text NOT NULL,
  code          text NOT NULL,
  supplier_name text,
  balance       numeric(16,3) NOT NULL,   -- الرصيد وقت كتابة السبب
  note          text NOT NULL,
  created_by    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sbn_note_not_blank CHECK (btrim(note) <> '')
);

-- آخر ملاحظة لمورد في فرع = أول صف في الترتيب ده
CREATE INDEX IF NOT EXISTS sbn_lookup_idx ON public.supplier_balance_notes (branch, code, created_at DESC);
CREATE INDEX IF NOT EXISTS sbn_branch_idx ON public.supplier_balance_notes (branch);

REVOKE ALL ON public.supplier_balance_notes FROM anon;
REVOKE ALL ON SEQUENCE public.supplier_balance_notes_id_seq FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.supplier_balance_notes TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.supplier_balance_notes_id_seq TO authenticated;

ALTER TABLE public.supplier_balance_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sbn_authenticated ON public.supplier_balance_notes;
CREATE POLICY sbn_authenticated ON public.supplier_balance_notes
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

COMMIT;

-- ── فحص ────────────────────────────────────────────────────────────
-- select branch, code, balance, note, created_at
--   from public.supplier_balance_notes order by created_at desc limit 10;
