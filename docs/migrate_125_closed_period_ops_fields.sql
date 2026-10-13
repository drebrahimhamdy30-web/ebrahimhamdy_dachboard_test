/* ============================================================
   حارس الفترة المقفولة: يقفل الأرقام مش الصف كله
   ------------------------------------------------------------
   المشكلة: trg_block_closed_period بيرفض أي UPDATE على صف تاريخه
   داخل فترة مقفولة. لكن في pos_wallet_transfers فيه حقول **تشغيلية**
   مالهاش أي أثر مالي:

     shift_id      → ختم الشيفت اللي حسب التحويل (منع التكرار)
     is_disbursed  → اتوردت للخزنة ولا لأ
     disbursed_at / disbursed_by → مين ورّد وإمتى

   pos_balance_upto بتجمع w.amount بس ومابتبصّش على أي منهم، فمنع
   تعديلهم مابيحميش قرش واحد — بالعكس بيكسر حاجتين:

   1) زرار «تم التوريد» بيرجع 400 لأي تحويل قبل تاريخ الإقفال.
   2) إغلاق الشيفت مابيعرفش يختم التحويل بـshift_id، فالتحويل يفضل
      «معلّق» ويتحسب في كل شيفت جديد. حصل فعلًا في المعمورة: تحويل
      553 ج اتحسب في ٣ شيفتات ورا بعض (963 و966 و967) — والإقفال
      كان لحد 2026-10-12 والتحويل اتسجّل 2026-10-12 11:45 م.

   الحل: نسمح بالتعديل **لو ده كل اللي اتغيّر**. المقارنة بتتعمل على
   الصف كله بعد ما نشيل الحقول دي، فأي تغيير في المبلغ أو الفرع أو
   التاريخ أو المحفظة يفضل ممنوع زي ما هو.

   باقي الجداول (pos_shifts / pos_manual_transfers / pos_branch_opening)
   محميّة بالكامل من غير أي استثناء.
   ============================================================ */
create or replace function public.trg_block_closed_period()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_claims text := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '');
  v_rows   jsonb[];
  v_row    jsonb;
  v_branch text;
  v_day    date;
  v_last   date;
BEGIN
  IF v_claims = '' OR coalesce(v_claims::jsonb ->> 'role', '') = 'service_role' THEN
    RETURN coalesce(NEW, OLD);
  END IF;

  /* استثناء الحقول التشغيلية — الأرقام مالهاش دعوة بيه */
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
    v_day := CASE TG_TABLE_NAME
               WHEN 'pos_shifts' THEN coalesce(
                      ((v_row ->> 'closed_at')::timestamptz AT TIME ZONE 'Africa/Cairo')::date,
                      (v_row ->> 'shift_date')::date)
               WHEN 'pos_wallet_transfers' THEN ((v_row ->> 'created_at')::timestamptz AT TIME ZONE 'Africa/Cairo')::date
               WHEN 'pos_manual_transfers' THEN ((v_row ->> 'txn_date')::timestamptz   AT TIME ZONE 'Africa/Cairo')::date
               WHEN 'pos_branch_opening'   THEN (v_row ->> 'as_of')::date
             END;
    IF v_branch IS NULL OR v_day IS NULL THEN CONTINUE; END IF;
    v_last := public.pos_last_close(v_branch);
    IF v_last IS NOT NULL AND v_day <= v_last THEN
      RAISE EXCEPTION 'الفترة مقفولة لفرع % لحد % — لازم الأدمن يفتح الإقفال الأول', v_branch, v_last
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  RETURN coalesce(NEW, OLD);
END $function$;
