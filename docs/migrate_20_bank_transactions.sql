-- ═══════════════════════════════════════════════════════════════════
-- متابعة الحساب البنكي: من جدول n8n لجدول في القاعدة + رفع كشف الحساب Excel
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-16)
--
-- ليه:
--   • المعاملات كانت في Data Table جوّه n8n (bmonline / bmonlinepost /
--     updatebmonlne)، والاستيراد التلقائي كان واقف من 14/9 الساعة 9:33 الصبح.
--   • التصنيف في n8n كان بيحط كل «POS PURCHASE» (شراء بكارت الحساب) باي موب
--     (11 معاملة)، وماكانش بيتعرّف على تحويلات أبو قير خالص (7 تحويلات
--     = 1,143,386 اتحطّوا «أخرى»).
--
-- دلوقتي:
--   • bank_transactions + bank_settings في القاعدة
--   • bank_classify() — قاعدة تصنيف واحدة بتتنفّذ على السيرفر بس
--   • RPCs بحراسة الدور (صلاحية صفحة bank_monitor)؛ رصيد البداية للأدمن بس
--   • منع التكرار: (رقم الحركة، المبلغ، الوقت) — رفع نفس الكشف مرتين آمن
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.bank_transactions (
  id            bigserial PRIMARY KEY,
  tx_at         timestamptz NOT NULL,            -- وقت المعاملة (القاهرة)
  value_date    date,                            -- تاريخ الحق
  amount        numeric(14,2) NOT NULL,          -- + وارد / - صادر
  description   text,                            -- البيان / الوصف اليدوي
  bank_no       text,                            -- رقم الحركة (فاضي لليدوي)
  ref_no        text,                            -- الرقم المرجعي
  doc_no        text,                            -- رقم المستند
  tx_code       text,                            -- كود الحركة (IPC / CPC / PUR ...)
  balance_after numeric(14,2),                   -- الرصيد بعد المعاملة
  source        text NOT NULL CHECK (source IN ('instapay','paymob','abuqir','other')),
  source_auto   text,                            -- اللي قاله المصنّف (لو اتغيّر يدوي)
  source_set_by text,
  is_posted     boolean NOT NULL DEFAULT false,
  posted_at     timestamptz,
  posted_by     text,
  closed        boolean,
  is_excess     boolean,
  created_by    text,
  import_file   text,
  legacy_id     bigint,                          -- id في جدول n8n القديم
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_bank_tx_dedupe
  ON public.bank_transactions (bank_no, amount, tx_at) WHERE bank_no IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_bank_tx_legacy
  ON public.bank_transactions (legacy_id) WHERE legacy_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_bank_tx_at ON public.bank_transactions (tx_at DESC);
CREATE INDEX IF NOT EXISTS ix_bank_tx_pending ON public.bank_transactions (source) WHERE NOT is_posted;

CREATE TABLE IF NOT EXISTS public.bank_settings (
  key        text PRIMARY KEY,
  value      text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text
);

-- ── التصنيف ────────────────────────────────────────────────────────
-- الترتيب مهم: أبو قير قبل أي حاجة، وتسوية باي موب بالنص الصريح بس.
-- «POS PURCHASE» = شراء بكارت الحساب → أخرى (حتى لو المحل اسمه فيه PAYMOB).
CREATE OR REPLACE FUNCTION public.bank_classify(p_desc text, p_bank_no text, p_tx_code text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN coalesce(p_desc,'') ~* 'abu\s*qir'                                   THEN 'abuqir'
    WHEN coalesce(p_desc,'') ~* 'paymob\s+settlement'                        THEN 'paymob'
    WHEN coalesce(p_bank_no,'') ~ '^[0-9]{3}IPN'
      OR upper(coalesce(p_tx_code,'')) = 'IPC'
      OR coalesce(p_desc,'') ~* 'instant\s+transfer'                          THEN 'instapay'
    ELSE 'other'
  END;
$fn$;

-- ── الحراسة ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_can_use()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') = 'service_role'
      OR public.jwt_app_role() = 'admin'
      OR EXISTS (SELECT 1 FROM page_permissions pp
                  WHERE pp.page_key = 'bank_monitor' AND pp.role = public.jwt_app_role());
$fn$;

CREATE OR REPLACE FUNCTION public.bank_actor()
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    nullif(btrim(nullif(current_setting('request.jwt.claims', true),'')::jsonb -> 'app_metadata' ->> 'full_name'),''),
    nullif(btrim(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'full_name'),''),
    nullif(btrim(nullif(current_setting('request.jwt.claims', true),'')::jsonb -> 'app_metadata' ->> 'username'),''),
    'غير معروف');
$fn$;

ALTER TABLE public.bank_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_settings     ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bank_tx_read  ON public.bank_transactions;
DROP POLICY IF EXISTS bank_set_read ON public.bank_settings;
CREATE POLICY bank_tx_read  ON public.bank_transactions FOR SELECT TO authenticated USING (public.bank_can_use());
CREATE POLICY bank_set_read ON public.bank_settings     FOR SELECT TO authenticated USING (public.bank_can_use());
REVOKE ALL ON public.bank_transactions, public.bank_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.bank_transactions, public.bank_settings TO authenticated;

-- ── رفع كشف الحساب ──────────────────────────────────────────────────
-- p_rows: [{tx_at:'YYYY-MM-DD HH:MM:SS' (القاهرة), value_date, amount, description,
--           bank_no, ref_no, doc_no, tx_code, balance_after}]
-- p_dry_run = true → بيرجّع اللي هيحصل من غير ما يكتب (للمعاينة قبل التأكيد)
CREATE OR REPLACE FUNCTION public.bank_import_statement(p_rows jsonb, p_file text DEFAULT NULL, p_dry_run boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_total int; v_new int; v_bad int; v_by jsonb; v_ins int := 0;
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك');
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'البيانات مش بالشكل المتوقع');
  END IF;

  DROP TABLE IF EXISTS _in, _new;
  -- ⚠️ صف واحد بتاريخ أو مبلغ بايظ كان بيوقّع الرفع كله — دلوقتي بيتعدّ «غير صالح» ويتساب
  CREATE TEMP TABLE _in ON COMMIT DROP AS
  SELECT CASE WHEN (r ->> 'tx_at') ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$'
              THEN (r ->> 'tx_at')::timestamp AT TIME ZONE 'Africa/Cairo' END      AS tx_at,
         CASE WHEN (r ->> 'value_date') ~ '^\d{4}-\d{2}-\d{2}$' THEN (r ->> 'value_date')::date END AS value_date,
         CASE WHEN (r ->> 'amount') ~ '^-?\d+(\.\d+)?$' THEN round((r ->> 'amount')::numeric, 2) END AS amount,
         nullif(btrim(r ->> 'description'),'')                                     AS description,
         nullif(btrim(r ->> 'bank_no'),'')                                         AS bank_no,
         nullif(btrim(r ->> 'ref_no'),'')                                          AS ref_no,
         nullif(btrim(r ->> 'doc_no'),'')                                          AS doc_no,
         nullif(btrim(r ->> 'tx_code'),'')                                         AS tx_code,
         CASE WHEN (r ->> 'balance_after') ~ '^-?\d+(\.\d+)?$' THEN (r ->> 'balance_after')::numeric END AS balance_after
    FROM jsonb_array_elements(p_rows) r;

  SELECT count(*), count(*) FILTER (WHERE tx_at IS NULL OR amount IS NULL OR bank_no IS NULL)
    INTO v_total, v_bad FROM _in;
  DELETE FROM _in WHERE tx_at IS NULL OR amount IS NULL OR bank_no IS NULL;

  -- تكرار جوّه الملف نفسه
  DELETE FROM _in a USING _in b
   WHERE a.ctid > b.ctid AND a.bank_no = b.bank_no AND a.amount = b.amount AND a.tx_at = b.tx_at;

  CREATE TEMP TABLE _new ON COMMIT DROP AS
  SELECT i.*, public.bank_classify(i.description, i.bank_no, i.tx_code) AS source
    FROM _in i
   WHERE NOT EXISTS (SELECT 1 FROM bank_transactions t
                      WHERE t.bank_no = i.bank_no AND t.amount = i.amount AND t.tx_at = i.tx_at);

  SELECT count(*) INTO v_new FROM _new;
  SELECT coalesce(jsonb_object_agg(source, jsonb_build_object('count', n, 'sum', s)), '{}'::jsonb)
    INTO v_by FROM (SELECT source, count(*) n, sum(amount) s FROM _new GROUP BY source) x;

  IF NOT p_dry_run THEN
    INSERT INTO bank_transactions (tx_at, value_date, amount, description, bank_no, ref_no, doc_no,
                                   tx_code, balance_after, source, source_auto, created_by, import_file)
    SELECT tx_at, value_date, amount, description, bank_no, ref_no, doc_no, tx_code, balance_after,
           source, source, 'كشف حساب · ' || public.bank_actor(), p_file
      FROM _new
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_ins = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('success', true, 'dry_run', p_dry_run,
    'rows', v_total, 'invalid', v_bad, 'new', v_new,
    'inserted', v_ins, 'existing', v_total - v_bad - v_new, 'by_source', v_by);
END $fn$;

-- ── إضافة يدوية ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_add_manual(p_amount numeric, p_source text, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_id bigint;
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك'); END IF;
  IF p_amount IS NULL OR p_amount = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'اكتب المبلغ'); END IF;
  IF p_source NOT IN ('instapay','paymob','abuqir','other') THEN
    RETURN jsonb_build_object('success', false, 'error', 'مصدر غير معروف'); END IF;
  INSERT INTO bank_transactions (tx_at, amount, description, source, created_by)
  VALUES (now(), round(p_amount, 2), nullif(btrim(p_description),''), p_source, public.bank_actor())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'id', v_id);
END $fn$;

-- ── ترحيل (فردي أو جماعي) ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_post(p_ids bigint[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_n int;
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك'); END IF;
  UPDATE bank_transactions SET is_posted = true, posted_at = now(), posted_by = public.bank_actor()
   WHERE id = ANY(p_ids) AND NOT is_posted;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'posted', v_n);
END $fn$;

-- ── تعديل التصنيف يدوي (غير المرحّل بس) ────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_set_source(p_id bigint, p_source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_n int;
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك'); END IF;
  IF p_source NOT IN ('instapay','paymob','abuqir','other') THEN
    RETURN jsonb_build_object('success', false, 'error', 'مصدر غير معروف'); END IF;
  UPDATE bank_transactions SET source = p_source, source_set_by = public.bank_actor()
   WHERE id = p_id AND NOT is_posted;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'المعاملة مرحّلة — مينفعش تغيّر مصدرها'); END IF;
  RETURN jsonb_build_object('success', true);
END $fn$;

-- ── رصيد البداية (الأدمن بس) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_set_opening(p_value numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
BEGIN
  IF coalesce(public.jwt_app_role(),'') <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'رصيد البداية للأدمن بس'); END IF;
  IF p_value IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'أدخل رقم صحيح'); END IF;
  INSERT INTO bank_settings (key, value, updated_at, updated_by)
  VALUES ('opening_balance', p_value::text, now(), public.bank_actor())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
  RETURN jsonb_build_object('success', true);
END $fn$;

REVOKE ALL ON FUNCTION public.bank_import_statement(jsonb, text, boolean), public.bank_add_manual(numeric, text, text),
                     public.bank_post(bigint[]), public.bank_set_source(bigint, text), public.bank_set_opening(numeric),
                     public.bank_can_use() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bank_import_statement(jsonb, text, boolean), public.bank_add_manual(numeric, text, text),
                     public.bank_post(bigint[]), public.bank_set_source(bigint, text), public.bank_set_opening(numeric),
                     public.bank_can_use() TO authenticated, service_role;

COMMIT;

-- ── نقل البيانات القديمة (اتعمل مرة واحدة على البرودكشن) ──────────────
-- اتجابت الـ2070 معاملة من ويبهوك bmonline?type=get عن طريق net.http_get واتحطّت
-- بـlegacy_id. المعاملات التلقائية اتعاد تصنيفها بـbank_classify (اتغيّر 18:
-- 11 شراء بالكارت باي موب ← أخرى، و7 تحويلات أبو قير أخرى ← أبو قير)، واليدوي
-- اتساب بمصدره. رصيد البداية 248425 اتنقل. أرقام الشاشة اتطابقت بعد النقل:
-- الحالي 171,377.78 · المرحّل 162,984.28 · غير المرحّل 8,393.50.
