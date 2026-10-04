-- ═══════════════════════════════════════════════════════════════════
-- معايرة suggest_stock_codes — دقة أعلى وسرعة أعلى
-- ═══════════════════════════════════════════════════════════════════
-- القياس على عيّنة مرجعية (sugg_bench) = أصناف مكوّدة وكودها موجود في
-- المخزون. نفس العيّنة قبل وبعد:
--
--   150 صف:   القديمة 115 صح من أول اقتراح · الجديدة 122   (ضايع 7 → 5)
--   300 صف:   الجديدة 243 (81.0%) من أول اقتراح · 286 (95.3%) في أول تلاتة
--   السرعة:   384ms → ~75ms للنداء الواحد
--
-- ⚠️ ماتعدّلش الدالة من غير ما تشغّل القياس قبل وبعد. جرّبت أربع أفكار
--    «منطقية» وكلها طلعت بتضر، والعيّنة هي اللي كشفت:
--      • عقوبة «أرقام زيادة في المخزون» → أسماء المخزن بتشيل المقاس
--        («توينزول نقط» مقابل «توينزول نقط عين 5 مل») فكانت بتعاقب الصح.
--      • اعتبار أول رقم = التركيز → أول رقم عند المخزن غالبًا عدد العبوة
--        («باروفين اقراص 3شريط» مقابل «باروفين 30 قرص»).
--      • مكافأة تطابق أول كلمة بالحرف → بتطلّع أسماء عامة (صابون/كريم/صن).
--      • عمود «حروف الاسم بس» في الفلتر → مافرقش، واتشال بدل ما يفضل حِمل.
--
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ ① أعمدة محسوبة على stock_flat ═══
-- GENERATED STORED عن قصد: refresh_stock_flat بتعمل truncate + insert
-- بقايمة أعمدة صريحة، فأي عمود عادي كان هيفضل فاضي بعد كل ريفرش من غير
-- ما حد ياخد باله. المحسوب القاعدة بتملاه لوحدها فمستحيل يُنسى.
ALTER TABLE public.stock_flat
  ADD COLUMN IF NOT EXISTS n_sq   text   GENERATED ALWAYS AS (replace(ar_norm(n), ' ', '')) STORED,
  ADD COLUMN IF NOT EXISTS n_nums text[] GENERATED ALWAYS AS (num_tokens(n)) STORED;

COMMENT ON COLUMN public.stock_flat.n_sq IS
  'الاسم بدون مسافات — «كولاكوند» و«كولا كوند» يبقوا واحد';
COMMENT ON COLUMN public.stock_flat.n_nums IS
  'أرقام الاسم محسوبة مرة واحدة بدل regexp لكل صف في كل نداء — ده كان سبب البطء';

CREATE INDEX IF NOT EXISTS idx_stock_flat_nsq_trgm
  ON public.stock_flat USING gin (n_sq gin_trgm_ops);

-- ═══ ② الدالة ═══
-- التوقيع زي ما هو عن قصد — suggest_codes_for_names و
-- suggest_purchase_sources بينادوها، وأي تغيير في التوقيع بيكسرهم.
CREATE OR REPLACE FUNCTION public.suggest_stock_codes(p_name text, p_limit integer DEFAULT 10)
RETURNS TABLE(itm_code text, name text, company text, sim real)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  -- «2 شريط» عُرف عند المخازن (3,411 اسم) ومخزوننا مابيستخدمهوش (105 بس)،
  -- فالرقم ده ضوضاء وكان بيطيّح «زيلون اقراص 2 شريط» عن «زيلون 20مجم 20 قرص».
  clean text   := regexp_replace(coalesce(p_name,''), '[0-9٠-٩]+\s*(شريط|شرائط)', ' ', 'g');
  q     text   := ar_norm(clean);
  qsq   text   := replace(ar_norm(clean), ' ', '');
  w1    text   := split_part(ar_norm(clean), ' ', 1);
  w1s   text   := sort_letters(split_part(ar_norm(clean), ' ', 1));
  qn    text[] := num_tokens(clean);
BEGIN
  IF q = '' THEN RETURN; END IF;
  PERFORM set_limit(0.25);      -- 0.1 كان بيجيب 4,343 مرشّح بنفس الدقة بالظبط
  RETURN QUERY
  -- مرحلتين: فرز رخيص بالفهارس، والحساب الكامل على 150 مرشّح بس
  WITH cand AS (
    SELECT f.itm_code, f.n, f.co, f.n_fw, f.n_fw_sorted, f.n_norm, f.n_sq, f.n_nums,
           greatest(similarity(f.n_norm, q), similarity(f.n_sq, qsq), similarity(f.n_fw, w1)) AS pre
    FROM stock_flat f
    WHERE f.n_norm % q OR f.n_sq % qsq OR f.n_fw % w1
    ORDER BY pre DESC
    LIMIT 150
  )
  SELECT c.itm_code, c.n, c.co,
    (
      ( 0.6 * greatest( similarity(c.n_fw, w1),
                        similarity(c.n_fw_sorted, w1s),              -- حروف متبادلة: «زاليرتو»/«زاريلتو»
                        similarity(left(c.n_sq, length(w1)), w1) )    -- «كولا» جوّه «كولاكوند»
      + 0.4 * greatest( similarity(c.n_norm, q), similarity(c.n_sq, qsq) )
      )
      * CASE WHEN array_length(qn,1) IS NULL THEN 1.0
             ELSE 0.4 + 0.6 * ((SELECT count(*) FROM unnest(qn) z WHERE z = ANY(c.n_nums))::numeric
                               / array_length(qn,1)) END
    )::real AS sim
  FROM cand c
  ORDER BY sim DESC, c.n
  LIMIT greatest(1, least(p_limit, 30));
END $fn$;

-- ═══ ③ إحصاءات الجدول بعد إعادة البناء ═══
-- truncate+insert بيسيب الإحصاءات قديمة فخطة الاقتراح بتبوظ:
-- قيست 75ms تبقى 711ms لحد ما autovacuum يلحق، وده كل 10 دقايق.
DO $do$
DECLARE src text; new_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'refresh_stock_flat';

  IF src IS NULL THEN RAISE NOTICE 'refresh_stock_flat مش موجودة — اتخطّت'; RETURN; END IF;
  IF src ILIKE '%analyze public.stock_flat%' THEN RAISE NOTICE 'متطبّقة قبل كده'; RETURN; END IF;

  new_src := replace(src,
    '  perform public.refresh_purchase_orders();',
    '  analyze public.stock_flat;' || chr(10) || chr(10) ||
    '  perform public.refresh_purchase_orders();');

  IF new_src = src THEN
    RAISE EXCEPTION 'مش لاقي سطر refresh_purchase_orders — راجع الدالة بإيدك';
  END IF;
  EXECUTE new_src;
END $do$;

-- ═══ ④ العيّنة المرجعية ═══
CREATE TABLE IF NOT EXISTS public.sugg_bench (
  id bigint PRIMARY KEY, store text, item_name text, true_code text
);
COMMENT ON TABLE public.sugg_bench IS
  'عيّنة ثابتة لقياس دقة suggest_stock_codes. شغّل القياس قبل وبعد أي تعديل على الدالة.';

TRUNCATE public.sugg_bench;
INSERT INTO public.sugg_bench (id, store, item_name, true_code)
SELECT p.id, p.store, p.item_name, p.code
FROM store_item_prices p
WHERE p.code IS NOT NULL AND p.code <> '0'
  AND EXISTS (SELECT 1 FROM stock_flat f WHERE f.itm_code = p.code)
  AND p.id % 97 = 0;        -- عيّنة ثابتة موزّعة، مش عشوائية كل مرة

COMMIT;

-- بعد التشغيل: VACUUM ANALYZE public.stock_flat;   (مش جوّه transaction)
--
-- القياس:
--   WITH b AS (SELECT * FROM sugg_bench ORDER BY id LIMIT 300),
--   r AS (SELECT (SELECT min(x.rk) FROM (SELECT s.itm_code, row_number() OVER () rk
--          FROM suggest_stock_codes(b.item_name,5) s) x WHERE x.itm_code=b.true_code) rank FROM b)
--   SELECT count(*) filter (WHERE rank=1) top1, count(*) filter (WHERE rank<=3) top3,
--          count(*) filter (WHERE rank IS NULL) missed FROM r;
-- المتوقّع: 243 · 286 · 10
