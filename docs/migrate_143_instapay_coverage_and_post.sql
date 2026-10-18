/* ============================================================
   مطابقة ورديات انستاباي — (٢) التغطية + الترحيل بالوردية
   ------------------------------------------------------------
   ملاحظتين من المالك على migrate_142:

   ⚠️ (١) حركات انستاباي بتتسحب **يدويًا** (رفع كشف الحساب Excel).
   يعني آخر وردية (أو أكتر) ممكن تكون حركاتها لسه مااتسحبتش — ووقتها
   المقارنة بتقول «فرق» وهو مش فرق، ده كشف ناقص. ده خطر حقيقي لأنه
   بيورّي اتهام غلط لموظف.

   الحل: بنحسب **حد التغطية** = آخر حركة انستاباي متسحوبة. أي وردية
   إقفالها **بعد** الحد ده = `covered:false`، وبتتعرض «ناقص» بدل رقم
   الفرق، **وبتتشال من الإجماليات** عشان ما تلوّثهاش.

   ملحوظة بالأمانة: ده بيمسك الناقص **من الآخر** بس. لو الكشف نفسه
   كان ناقص حركة في النص، مفيش طريقة نعرفها — فالحد ده أقصى ضمان
   ممكن بالبيانات المتاحة.

   (٢) زر ترحيل: بعد المراجعة، المالك يحدّد الورديات اللي خلّصها
   وترحّل حركاتها كلها مرة واحدة بدل تحديد حركة حركة.
   `bank_post_shift_windows` بيستعمل **نفس** ختم وحراسة `bank_post`
   (bank_can_use + bank_actor) عشان الترحيل يفضل متسق.

   ⚠️ الدالة بترفض ترحيل وردية **غير مغطّاة** — ترحيلها معناه إقفال
   حركات لسه مانعرفهاش.
   ============================================================ */
create or replace function public.get_instapay_shift_match(
  p_days integer default 7,
  p_pending_only boolean default true)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_out jsonb;
  v_cov timestamptz;
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك');
  END IF;

  /* حد التغطية: آخر حركة انستاباي اتسحبت من الكشف */
  SELECT max(tx_at) INTO v_cov
    FROM bank_transactions WHERE source = 'instapay' AND amount > 0;

  WITH sh AS (
    SELECT s.id, s.branch, s.employee_name, s.closed_at,
           lag(s.closed_at) OVER (PARTITION BY s.branch ORDER BY s.closed_at) AS prev_closed,
           l.actual_amount AS declared
      FROM pos_shifts s
      JOIN pos_shift_lines l ON l.shift_id = s.id AND l.method_key = 'instapay'
     WHERE s.closed_at IS NOT NULL
  ),
  win AS (
    SELECT * FROM sh
     WHERE prev_closed IS NOT NULL
       AND closed_at >= now() - (greatest(coalesce(p_days, 7), 1)::text || ' days')::interval
  ),
  calc AS (
    SELECT w.*,
           coalesce(b.n, 0)         AS bank_n,
           coalesce(b.pending_n, 0) AS pending_n,
           coalesce(b.amt, 0)       AS actual,
           (v_cov IS NOT NULL AND w.closed_at <= v_cov) AS covered
      FROM win w
      LEFT JOIN LATERAL (
        SELECT count(*) AS n,
               count(*) FILTER (WHERE NOT t.is_posted) AS pending_n,
               sum(t.amount) AS amt
          FROM bank_transactions t
         WHERE t.source = 'instapay' AND t.amount > 0
           AND t.tx_at > w.prev_closed AND t.tx_at <= w.closed_at
      ) b ON true
  ),
  f AS (
    SELECT * FROM calc
     /* الوردية غير المغطّاة بتفضل ظاهرة دايمًا — حتى لو مفيش فيها
        حركة معلّقة — عشان المالك يعرف إن الكشف لسه ناقص */
     WHERE NOT coalesce(p_pending_only, true) OR pending_n > 0 OR NOT covered
  )
  SELECT jsonb_build_object(
    'success', true,
    'coverage_at', v_cov,
    'rows', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'shift_id',  f.id,
               'branch',    f.branch,
               'employee',  f.employee_name,
               'from_at',   f.prev_closed,
               'to_at',     f.closed_at,
               'actual',    round(f.actual, 2),
               'declared',  round(coalesce(f.declared, 0), 2),
               'diff',      round(f.actual - coalesce(f.declared, 0), 2),
               'bank_n',    f.bank_n,
               'pending_n', f.pending_n,
               'covered',   f.covered)
             ORDER BY f.closed_at DESC)
        FROM f), '[]'::jsonb),
    /* ⚠️ الإجماليات على المغطّى بس — الوردية اللي كشفها ناقص رقمها
       مش حقيقي فمينفعش يدخل المجموع */
    'totals', (
      SELECT jsonb_build_object(
               'shifts',    count(*),
               'actual',    round(coalesce(sum(actual), 0), 2),
               'declared',  round(coalesce(sum(coalesce(declared, 0)), 0), 2),
               'diff',      round(coalesce(sum(actual - coalesce(declared, 0)), 0), 2),
               'bad',       count(*) FILTER (WHERE round(actual - coalesce(declared, 0), 2) <> 0))
        FROM f WHERE covered),
    'uncovered', (SELECT count(*) FROM f WHERE NOT covered)
  ) INTO v_out;

  RETURN v_out;
END $function$;

/* ---------- ترحيل كل حركات ورديات محددة ---------- */
create or replace function public.bank_post_shift_windows(p_shift_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_cov    timestamptz;
  v_n      int;
  v_picked int;
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك');
  END IF;
  IF p_shift_ids IS NULL OR array_length(p_shift_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'مفيش ورديات محددة');
  END IF;

  SELECT max(tx_at) INTO v_cov
    FROM bank_transactions WHERE source = 'instapay' AND amount > 0;

  WITH sh AS (
    SELECT s.id, s.branch, s.closed_at,
           lag(s.closed_at) OVER (PARTITION BY s.branch ORDER BY s.closed_at) AS prev_closed
      FROM pos_shifts s
      JOIN pos_shift_lines l ON l.shift_id = s.id AND l.method_key = 'instapay'
     WHERE s.closed_at IS NOT NULL
  ),
  pick AS (
    /* ⚠️ الوردية غير المغطّاة بتتشال هنا — ترحيلها معناه إقفال حركات
       لسه مااتسحبتش من الكشف */
    SELECT * FROM sh
     WHERE id = ANY(p_shift_ids)
       AND prev_closed IS NOT NULL
       AND v_cov IS NOT NULL AND closed_at <= v_cov
  ),
  upd AS (
    UPDATE bank_transactions t
       SET is_posted = true, posted_at = now(), posted_by = public.bank_actor()
      FROM pick p
     WHERE t.source = 'instapay' AND t.amount > 0 AND NOT t.is_posted
       AND t.tx_at > p.prev_closed AND t.tx_at <= p.closed_at
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM upd), (SELECT count(*) FROM pick)
    INTO v_n, v_picked;

  RETURN jsonb_build_object(
    'success', true,
    'posted', v_n,
    'shifts', v_picked,
    'skipped', array_length(p_shift_ids, 1) - v_picked);
END $function$;

/* ⚠️ PUBLIC بياخد EXECUTE افتراضيًا — السحب الصريح لازم (migrate_89/90) */
revoke all on function public.bank_post_shift_windows(bigint[]) from public, anon;
grant execute on function public.bank_post_shift_windows(bigint[]) to authenticated, service_role;
