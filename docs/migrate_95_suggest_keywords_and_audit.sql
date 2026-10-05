-- ═══════════════════════════════════════════════════════════════════
-- اقتراح الأكواد: ملاذ «الكلمة المميزة» + مراجعة التكويد القديم
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ الأرقام مكرّرة في docs/ (فيه migrate_80..83 مرتين) — ده الملف رقم 95
--    عشان 84..94 محجوزين. بُص على آخر رقم موجود قبل ما تضيف ملف جديد.
--
-- ═══ ① ليه الملاذ ده ═══
-- الدالة بتوزن أول كلمة بـ0.6، وده بيقع لما الاسم مكتوب بترتيب مختلف:
--   عابدين: «حمض فوليك ميباكو»  ·  مخزوننا: «فوليك اسيد 500 ميكروجرام ميباكو»
-- أول كلمة «حمض» بتطابق «حمام» (0.286) أحسن ما بتطابق «فوليك» (0.0)،
-- فـ«حمام كريم مينك» بيكسب على الصنف الصح. الصنف الصح كان **بره أول 5**.
--
-- الحل: أحسن كلمة مميزة مشتركة بين الاسمين — بس **محصور عن قصد**:
-- مابيشتغلش إلا لما مفيش ولا مرشّح نتيجته فوق 0.38، يعني الدالة رايحة
-- تفشل أصلًا، فمستحيل يزيح إجابة واثقة.
--
-- ═══ ② القياس — اقرأه قبل ما تعدّل ═══
-- جُرّبت الفكرة بخمس صور. أربعة ضرّوا:
--   • بديل لحد أول كلمة            → 165 ← 159
--   • خلط بوزن 0.25 / 0.40 / 0.55  → تعادل أو أسوأ
--   • مكافأة عند تغطية عالية        → تعادل
--   • ببوابة «أول كلمة ضعيفة»       → 165 ← 160
--   • ملاذ محصور (المشحون)          → 165 ← 167  ✅
-- النتيجة النهائية: عابدين 167/200 أول اقتراح · العامة 162/200.
-- المكسب صغير (داخل حدود الضوضاء) بس بيصلّح عيلة فشل تام حقيقية.
--
-- ⚠️ 57% من حالات الفشل الباقية = «الدوا صح والعبوة غلط» — والعبوة مش
--    مكتوبة في اسم المخزن أصلًا، فدي مشكلة معلومة ناقصة مش خوارزمية.
--    جُرّب السعر كمُرجِّح للعبوة في تلات صور وفشل (166 مقابل 165).
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ الكلمات المميزة في الاسم ═══
CREATE OR REPLACE FUNCTION public.ar_key_words(t text) RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  select coalesce(array_agg(w), '{}')
  from regexp_split_to_table(ar_norm(coalesce(t,'')), '\s+') w
  where length(w) >= 4
    and w !~ '[0-9]'
    and w not in ('اقراص','قرص','كبسول','كبسولة','كبسوله','كبسولات','امبول','امبولة','امبولات',
                  'شراب','كريم','مرهم','لوسيون','لوشن','محلول','معلق','بخاخ','اسبراى','سبراى',
                  'نقط','قطرة','قطره','لبوس','اقماع','فيال','اكياس','كيس','جرام','ملل','مللى',
                  'مجم','ميكروجرام','وحده','وحدة','مكجم','جديد','عرض','مكمل','غذائي','غذائى',
                  'للاطفال','اطفال','كبار','تلاجه','تلاجة','ثلاجة','ملغي','ملغى');
$$;

-- GENERATED STORED عن قصد: refresh_stock_flat بتعمل truncate+insert بقايمة
-- أعمدة صريحة، فعمود عادي كان هيفضل فاضي بعد كل ريفرش من غير ما حد ياخد باله.
ALTER TABLE public.stock_flat
  ADD COLUMN IF NOT EXISTS n_kw text[] GENERATED ALWAYS AS (ar_key_words(n)) STORED;
COMMENT ON COLUMN public.stock_flat.n_kw IS
  'الكلمات المميزة في الاسم (٤ حروف فأكتر، بدون أرقام وبدون كلمات عامة) — للمطابقة لما الكلمة المشتركة مش أول كلمة';

-- ═══ الدالة ═══
CREATE OR REPLACE FUNCTION public.suggest_stock_codes(p_name text, p_limit integer DEFAULT 10)
RETURNS TABLE(itm_code text, name text, company text, sim real)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  clean text := coalesce(p_name,'');
  q text; qsq text; w1 text; w1s text; qn text[]; qkw text[];
BEGIN
  -- ضوضاء من أسماء المخازن مالهاش مقابل في مخزوننا:
  --   «2 شريط» → 3,411 اسم عندهم مقابل 105 عندنا
  --   «108ج»   → عابدين بيحط السعر جوّه الاسم (56% من أصنافه)
  clean := regexp_replace(clean, '[0-9٠-٩]+\s*(شريط|شرائط)', ' ', 'g');
  clean := regexp_replace(clean, '[0-9٠-٩]+(\.[0-9]+)?\s*ج(?![مرا])', ' ', 'g');
  clean := regexp_replace(clean, '[*]+', ' ', 'g');
  clean := regexp_replace(clean, '(سعر جديد|سعر|س ج|قديم|ثلاجه|ثلاجة)', ' ', 'g');

  q   := ar_norm(clean);
  qsq := replace(ar_norm(clean), ' ', '');
  w1  := split_part(ar_norm(clean), ' ', 1);
  w1s := sort_letters(split_part(ar_norm(clean), ' ', 1));
  qn  := num_tokens(clean);
  qkw := ar_key_words(clean);
  IF q = '' THEN RETURN; END IF;

  PERFORM set_limit(0.25);
  RETURN QUERY
  WITH cand AS (
    SELECT f.itm_code, f.n, f.co, f.n_fw, f.n_fw_sorted, f.n_norm, f.n_sq, f.n_nums, f.n_kw,
           greatest(similarity(f.n_norm, q), similarity(f.n_sq, qsq), similarity(f.n_fw, w1)) AS pre
    FROM stock_flat f
    WHERE f.n_norm % q OR f.n_sq % qsq OR f.n_fw % w1
    ORDER BY pre DESC
    LIMIT 150
  ),
  sc AS (
    SELECT c.itm_code, c.n, c.co,
      (( 0.6 * greatest( similarity(c.n_fw, w1),
                         similarity(c.n_fw_sorted, w1s),              -- حروف متبادلة
                         similarity(left(c.n_sq, length(w1)), w1) )   -- «كولا» جوّه «كولاكوند»
       + 0.4 * greatest( similarity(c.n_norm, q), similarity(c.n_sq, qsq) ))
       * CASE WHEN array_length(qn,1) IS NULL THEN 1.0
              ELSE 0.4 + 0.6 * ((SELECT count(*) FROM unnest(qn) z WHERE z = ANY(c.n_nums))::numeric
                                / array_length(qn,1)) END)::real AS base,
      coalesce((SELECT max(similarity(a,b)) FROM unnest(qkw) a, unnest(c.n_kw) b), 0)::real AS kw
    FROM cand c
  ),
  m AS (SELECT sc.*, max(sc.base) OVER () AS best FROM sc)
  SELECT m.itm_code, m.n, m.co,
         (CASE WHEN m.best < 0.38 THEN greatest(m.base, m.kw * 0.9::real) ELSE m.base END)::real AS sim
  FROM m
  ORDER BY (CASE WHEN m.best < 0.38 THEN greatest(m.base, m.kw * 0.9::real) ELSE m.base END) DESC, m.n
  LIMIT greatest(1, least(p_limit, 30));
END $fn$;

-- ═══ ③ مراجعة التكويد القديم ═══
-- الكاشف: الكود المسجّل مافيهوش ولا كلمة مميزة مشتركة مع اسم المخزن (<0.40)
-- **و** الدالة بتقترح كود مختلف. الشرط التاني مهم: من غيره الإنذارات الكاذبة
-- بتغرق النتيجة (اتقاست: 1 حقيقي من 7 بالشرط الأول لوحده).
CREATE TABLE IF NOT EXISTS public.sip_code_audit (
  id bigint PRIMARY KEY,
  store text, item_name text,
  cur_code text, cur_name text, cur_sim real,
  sug_code text, sug_name text, sug_sim real,
  gap real, severity text,
  checked_at timestamptz DEFAULT now()
);
COMMENT ON TABLE public.sip_code_audit IS
  'مراجعة التكويد القديم: صفوف مكوّدة الدالة شايفة إن فيه كود أقرب بكتير. للمراجعة اليدوية — ممنوع التصحيح التلقائي.';

COMMIT;

-- ═══ إعادة بناء المراجعة (مش جوّه transaction عشان بتاخد وقت) ═══
--
-- ١) المرحلة الرخيصة:
--   TRUNCATE sip_code_audit;
--   INSERT INTO sip_code_audit (id, store, item_name, cur_code, cur_name, cur_sim)
--   SELECT p.id, p.store, p.item_name, p.code, cf.n,
--          coalesce((SELECT max(similarity(a,b))
--                    FROM unnest(ar_key_words(p.item_name)) a, unnest(cf.n_kw) b),0)::real
--   FROM store_item_prices p JOIN stock_flat cf ON cf.itm_code = p.code
--   WHERE p.available IS TRUE AND p.code IS NOT NULL AND p.code <> '0'
--     AND array_length(ar_key_words(p.item_name),1) IS NOT NULL
--     AND coalesce((SELECT max(similarity(a,b))
--                   FROM unnest(ar_key_words(p.item_name)) a, unnest(cf.n_kw) b),0) < 0.40;
--
-- ٢) املا الاقتراح على دفعات (كل دفعة ٤٠٠-٦٠٠ صف عشان مهلة الاستعلام):
--   UPDATE sip_code_audit a SET sug_code=g.itm_code, sug_name=g.name, sug_sim=g.sim,
--          gap=g.sim-a.cur_sim, checked_at=now()
--   FROM (SELECT t.id, s.itm_code, s.name, s.sim
--         FROM (SELECT id,item_name FROM sip_code_audit WHERE sug_code IS NULL ORDER BY id LIMIT 500) t
--         CROSS JOIN LATERAL (SELECT * FROM suggest_stock_codes(t.item_name,1) LIMIT 1) s) g
--   WHERE a.id=g.id;
--
-- ٣) شيل اللي الدالة وافقت على كوده، وصنّف الباقي:
--   DELETE FROM sip_code_audit WHERE sug_code IS NOT NULL AND sug_code = cur_code;
--   UPDATE sip_code_audit SET severity = CASE
--     WHEN cur_name ~ '^[^؀-ۿa-zA-Z]*$' THEN 'اسم خردة'
--     WHEN split_part(ar_norm(cur_name),' ',1) = split_part(ar_norm(sug_name),' ',1)
--       THEN 'نفس الدوا — عبوة/شكل'
--     WHEN gap > 0.80 THEN 'صنف مختلف تمامًا'
--     WHEN gap > 0.50 THEN 'مشكوك بقوة'
--     ELSE 'مشكوك' END;
--
-- نتيجة التشغيل الأول (2026-10-05): 581 صف من 36,871 مكوّد —
--   اسم خردة 19 · صنف مختلف تمامًا 80 · مشكوك بقوة 185 · عبوة/شكل 116 · مشكوك 181
