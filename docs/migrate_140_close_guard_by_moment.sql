/* ============================================================
   إقفال الفترة: لحظة بدل تاريخ — (٢) الحارس ودالة الإقفال
   ------------------------------------------------------------
   يكمّل migrate_139. الحارس بقى يقارن **لحظة** الصف بلحظة الإقفال
   بدل مقارنة التواريخ.

   السيناريو اللي كان بيكسر، واتجرّب بعد التعديل:
     المراجع قفل الساعة ١ ظهرًا · وردية شغّالة من ٩ص لـ٥م
       ١) الوردية بتتقفل ٥ م                      → عدّت ✓
       ٢) ختم تحويل محفظة اتسجّل ١٠ ص برقم الوردية → عدّى ✓
       ٣) توريد نفس التحويل                        → عدّى ✓
       ٤) تعديل **مبلغ** تحويل قبل الإقفال          → اترفض ✓
       ٥) وردية اتقفلت ١٢ ظهرًا (قبل لحظة الإقفال)  → اترفضت ✓

   يعني الحماية على اللي اتراجع فعلًا فضلت كاملة، واللي بعد لحظة
   المراجعة بقى حر.

   ⚠️ استثناء الحقول التشغيلية (ختم الوردية والتوريد) من migrate_125
   فضل زي ما هو وبيتفحص **قبل** أي مقارنة بالوقت.

   ⚠️ pos_close_period: لو التاريخ المختار هو النهاردة → اللحظة =
   now()، وأي تاريخ قديم → نهاية يومه (نفس السلوك القديم). وكمان
   منع الإقفال المكرر بقى بالمقارنة باللحظة، فينفع تقفل أكتر من مرة
   في نفس اليوم (كل مرة بتغطّي اللي اتقفل بعد المرة اللي قبلها).
   ============================================================ */
create or replace function public.trg_block_closed_period()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_claims  text := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '');
  v_rows    jsonb[];
  v_row     jsonb;
  v_branch  text;
  v_ts      timestamptz;
  v_last_at timestamptz;
BEGIN
  IF v_claims = '' OR coalesce(v_claims::jsonb ->> 'role', '') = 'service_role' THEN
    RETURN coalesce(NEW, OLD);
  END IF;

  /* الحقول التشغيلية على تحويلات المحافظ مالهاش أثر مالي (ختم الوردية
     والتوريد) — مسموحة حتى جوّه فترة مقفولة. أي تغيير في المبلغ/الفرع/
     التاريخ يفضل ممنوع. (migrate_125) */
  IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'pos_wallet_transfers'
     AND (to_jsonb(OLD) - 'shift_id' - 'is_disbursed' - 'disbursed_at' - 'disbursed_by')
       = (to_jsonb(NEW) - 'shift_id' - 'is_disbursed' - 'disbursed_at' - 'disbursed_by')
  THEN
    RETURN NEW;
  END IF;

  v_rows := ARRAY[]::jsonb[];
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_rows := v_rows || to_jsonb(OLD); END IF;
  IF TG_OP IN ('UPDATE', 'INSERT') THEN v_rows := v_rows || to_jsonb(NEW); END IF;

  FOREACH v_row IN ARRAY v_rows LOOP
    v_branch := v_row ->> 'branch';
    /* ⚠️ المقارنة باللحظة مش بالتاريخ: المراجع بيقفل الورديات اللي
       اتقفلت فعلًا لحد ساعته، والوردية الشغّالة مالهاش علاقة. */
    v_ts := CASE TG_TABLE_NAME
              WHEN 'pos_shifts' THEN coalesce(
                     (v_row ->> 'closed_at')::timestamptz,
                     (((v_row ->> 'shift_date')::date + 1)::timestamp at time zone 'Africa/Cairo'))
              WHEN 'pos_wallet_transfers' THEN (v_row ->> 'created_at')::timestamptz
              WHEN 'pos_manual_transfers' THEN (v_row ->> 'txn_date')::timestamptz
              WHEN 'pos_branch_opening'   THEN
                     (((v_row ->> 'as_of')::date + 1)::timestamp at time zone 'Africa/Cairo')
            END;
    IF v_branch IS NULL OR v_ts IS NULL THEN CONTINUE; END IF;
    v_last_at := public.pos_last_close_at(v_branch);
    IF v_last_at IS NOT NULL AND v_ts <= v_last_at THEN
      RAISE EXCEPTION 'الفترة مقفولة لفرع % لحد % — لازم الأدمن يفتح الإقفال الأول',
        v_branch, to_char(v_last_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI')
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  RETURN coalesce(NEW, OLD);
END $function$;

create or replace function public.pos_close_period(
  p_branch text, p_upto date, p_actual numeric, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_role  text  := coalesce(public.jwt_app_role(), '');
  v_pg    text  := coalesce(claims ->> 'role', '');
  v_canon text;
  v_today date  := (now() at time zone 'Africa/Cairo')::date;
  v_at    timestamptz;
  v_last_at timestamptz;
  v_sys   numeric;
  v_diff  numeric;
  v_who   text;
  r       pos_period_closes%ROWTYPE;
BEGIN
  IF v_pg <> 'service_role' AND v_role NOT IN ('accountant', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'إقفال الفترة للمحاسب والأدمن بس');
  END IF;

  SELECT b.name INTO v_canon FROM branches b
   WHERE replace(b.name, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى')
      OR EXISTS (SELECT 1 FROM unnest(coalesce(b.aliases, '{}')) a
                  WHERE replace(a, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى'))
   LIMIT 1;
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'فرع غير معروف');
  END IF;

  IF p_upto IS NULL OR p_upto > v_today THEN
    RETURN jsonb_build_object('success', false, 'error', 'تاريخ الإقفال لازم يكون النهاردة أو قبله');
  END IF;

  /* لو التاريخ هو النهاردة فالإقفال «لحد دلوقتي» — ده اللي بيخلّي
     الوردية الشغّالة ما تتأثرش. وأي تاريخ قديم = نهاية يومه. */
  v_at := CASE WHEN p_upto = v_today THEN now()
               ELSE ((p_upto + 1)::timestamp at time zone 'Africa/Cairo') END;

  v_last_at := public.pos_last_close_at(v_canon);
  IF v_last_at IS NOT NULL AND v_at <= v_last_at THEN
    RETURN jsonb_build_object('success', false, 'error',
      'الفترة مقفولة لحد ' || to_char(v_last_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI')
      || ' — اختار وقت بعده، أو افتح الإقفال الأول');
  END IF;

  v_sys  := public.pos_balance_at(v_canon, v_at);
  v_diff := round(coalesce(p_actual, 0) - v_sys, 2);
  IF abs(v_diff) > 0.009 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'الرصيد الفعلي مش مطابق — النظام ' || trim(to_char(v_sys, 'FM999999999990.00'))
      || ' والفعلي ' || trim(to_char(coalesce(p_actual, 0), 'FM999999999990.00'))
      || ' (فرق ' || trim(to_char(v_diff, 'FM999999999990.00')) || '). صلّح الفرق الأول وبعدين اقفل.',
      'system', v_sys, 'actual', coalesce(p_actual, 0), 'diff', v_diff);
  END IF;

  v_who := btrim(coalesce(claims -> 'app_metadata' ->> 'full_name',
                          claims -> 'app_metadata' ->> 'username', ''));
  INSERT INTO pos_period_closes (branch, upto, upto_at, balance, note, closed_by)
  VALUES (v_canon, p_upto, v_at, v_sys, nullif(btrim(coalesce(p_note, '')), ''), nullif(v_who, ''))
  RETURNING * INTO r;

  RETURN jsonb_build_object('success', true, 'row', to_jsonb(r), 'balance', v_sys);
END $function$;
