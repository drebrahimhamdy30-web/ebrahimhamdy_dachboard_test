-- ═══════════════════════════════════════════════════════════════════
--  migrate_29 — آخر فرق بين السيرفر الذاتي والبرودكشن: الفهارس
-- ═══════════════════════════════════════════════════════════════════
--  الجولة التانية من المقارنة طلّعت ٤ جداول بس:
--
--  1) wallet — ناقصه فهرس على bank_settled. طبيعي: العمود نفسه اتضاف
--     في migrate_28 والفهرس مالحقش ييجي معاه. شاشة «مبيعات الماكينات»
--     بتفلتر بيه.
--
--  2) stock_bishr / stock_mamora / stock_san — كل واحد فيه **فهرسين
--     متطابقين** على itm_code بدل واحد. أثر جانبي من الترحيل الأصلي:
--     الجدول كان اسمه *_staging واتعمله الفهرس مرتين، فبوستجرس سمّى
--     التاني بلاحقة 1. الاتنين UNIQUE على نفس العمود — اتأكدنا من
--     تعريفهم قبل الحذف، فمسح واحد مابيضيّعش الحماية من التكرار.
--
--     ⚠️ اللي بيتمسح هو اللي **مش موجود في البرودكشن**، عشان أسماء
--     الفهارس تفضل زي بعضها في الجهتين (san عكس التانيين — مقصود).
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── ١) فهرس التسوية البنكية ─────────────────────────────────────────
CREATE INDEX IF NOT EXISTS wallet_bank_settled_idx
  ON public.wallet USING btree (bank_settled);

-- ── ٢) الفهارس المكررة من الترحيل ───────────────────────────────────
DROP INDEX IF EXISTS public.stock_bishr_staging_itm_code_idx;   -- البرودكشن ماسك idx1
DROP INDEX IF EXISTS public.stock_mamora_staging_itm_code_idx;  -- البرودكشن ماسك idx1
DROP INDEX IF EXISTS public.stock_san_staging_itm_code_idx1;    -- البرودكشن ماسك idx

COMMIT;

-- ── الفحص: لازم يفضل فهرس UNIQUE واحد على كل جدول ───────────────────
SELECT tablename AS "الجدول", count(*) AS "عدد الفهارس",
       string_agg(indexname, ', ' ORDER BY indexname) AS "الأسماء"
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN ('stock_bishr','stock_mamora','stock_san','wallet')
GROUP BY tablename
ORDER BY tablename;
