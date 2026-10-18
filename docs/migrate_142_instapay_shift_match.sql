/* ============================================================
   مطابقة ورديات انستاباي — المقارنة على السيرفر
   ------------------------------------------------------------
   المالك كان بيفلتر انستاباي في شاشة البنك ويبص بعينه: هل الموظف
   قفل الوردية بالقيمة الصح؟ الدالة دي بتعمل المقارنة أوتوماتيك.

   المنطق: كل وردية ليها نافذة = من إقفال الوردية اللي قبلها (نفس
   الفرع) لحد إقفالها هي. بنجمع حركات انستاباي الواردة في النافذة
   دي ونقارنها باللي الموظف سجّله في `pos_shift_lines.actual_amount`
   لوسيلة `instapay`.

   اتأكد على بيانات حقيقية (المعمورة 10-14 → 10-18): **٨ من ١٤
   وردية مطابقة بالمليم**، والفروق ليها نمط واحد واضح:
     · منار 10-14 → فرق 261  = **بالظبط** وردية نور اللي قبلها
     · وحيد 10-18 → فرق 4033 = **بالظبط** وردية NOUR اللي قبلها
   يعني بعض الموظفين بيدخّلوا رصيد انستاباي **التراكمي** من غير ما
   يطرحوا وردية اللي قبلهم. ونجار 10-16 العكس: البنك أكبر بـ139،
   يعني تحصيل مادخلش الإقفال.

   ⚠️ القيمة الفعلية بتتحسب على **كل** حركات النافذة مش غير المرحّل
   بس — وإلا أول ما يرحّل حركة الفرق يتغيّر ويبان خطأ وهمي. اللي
   بيتفلتر بـ«غير المرحّل» هو **عرض الوردية** (يعني الورديات اللي
   لسه فيها حاجة مامتراجعتش)، مش الحساب.

   ⚠️ النتيجة jsonb (صف واحد) فمش متأثرة بسقف الـ1000 صف، والمجاميع
   بتتحسب في القاعدة على كل الورديات المفلترة.

   الفهارس: `ix_bank_tx_at` (tx_at DESC) كفاية للنوافذ دي — نافذة
   الوردية ساعات معدودة. مفيش فهرس جديد بقصد.
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
BEGIN
  IF NOT public.bank_can_use() THEN
    RETURN jsonb_build_object('success', false, 'error', 'مالكش صلاحية على متابعة البنك');
  END IF;

  WITH sh AS (
    /* النافذة بتتبني على **كل** الورديات مش المفلترة بالفترة، عشان
       أول وردية في الفترة تلاقي اللي قبلها */
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
           coalesce(b.amt, 0)       AS actual
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
     WHERE NOT coalesce(p_pending_only, true) OR pending_n > 0
  )
  SELECT jsonb_build_object(
    'success', true,
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
               'pending_n', f.pending_n)
             ORDER BY f.closed_at DESC)
        FROM f), '[]'::jsonb),
    'totals', (
      SELECT jsonb_build_object(
               'shifts',   count(*),
               'actual',   round(coalesce(sum(actual), 0), 2),
               'declared', round(coalesce(sum(coalesce(declared, 0)), 0), 2),
               'diff',     round(coalesce(sum(actual - coalesce(declared, 0)), 0), 2),
               'bad',      count(*) FILTER (WHERE round(actual - coalesce(declared, 0), 2) <> 0))
        FROM f)
  ) INTO v_out;

  RETURN v_out;
END $function$;

/* ⚠️ PUBLIC بياخد EXECUTE افتراضيًا — لازم السحب الصريح (migrate_89/90) */
revoke all on function public.get_instapay_shift_match(integer, boolean) from public, anon;
grant execute on function public.get_instapay_shift_match(integer, boolean) to authenticated, service_role;
