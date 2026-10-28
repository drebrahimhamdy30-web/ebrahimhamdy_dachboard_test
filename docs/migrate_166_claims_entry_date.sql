/* ════════════════════════════════════════════════════════════════
   المطالبات: التاريخ = تاريخ الإدخال مش تاريخ فاتورة المورّد
   (2026-10-28)
   ----------------------------------------------------------------
   المالك لاحظ إن فاتورة ١٧٥٦٧٦ (عابدين · سيدى بشر) ظاهرة عندنا
   بتاريخ ١٥/١٠ وفي كشف حساب eplus بتاريخ ١٧/١٠. البيانات مش غلط —
   دول **تاريخين**:
     • `ven_bill_date`    = التاريخ المكتوب على فاتورة المورّد (١٥/١٠)
     • `sec_insert_date`  = وقت تسجيلها على النظام        (١٧/١٠ ٦:٢١م)
   وكشف حساب المورّد في eplus بيترتّب بـ**تاريخ الحركة** يعني الإدخال
   (رقم المستند في الكشف = `pth_id` عندنا — 2387 — ده أكّد التطابق).

   ليه ده مهم مش شكلي: فلتر «من/إلى» في شاشة المطالبات كان شغّال على
   تاريخ الفاتورة، فالفاتورة اللي بتتسجّل بعد تاريخها بأيام كانت
   تقع في مطالبة شهر وفي الكشف في شهر تاني — فمقارنة إجمالياتنا
   بالكشف تطلع مش مظبوطة من غير سبب واضح.
   المقاس: **٤٤٢ فاتورة من ٦٤٤٩** في آخر ٩٠ يوم (٦.٩٪) تاريخها مختلف
   عن تاريخ إدخالها، وأكبر فرق **٣١ يوم**.

   وكمان الشاشة نفسها كانت بتخلط: المرتجعات بتمشي على
   `sec_insert_date/sec_update_date` والفواتير على `ven_bill_date`.
   دلوقتي الاتنين على تاريخ الإدخال.

   تاريخ فاتورة المورّد مابيتعرضش في الشاشة (قرار المالك: مش محتاجه)،
   بس الدالة بترجّعه في `inv_date` لو احتجناه بعدين.

   ⚠️ ده بيغيّر أساس الفلترة، فمطالبة اتقفلت قبل كده بفواتير تاريخ
   إدخالها بره المدى القديم ممكن تبان بترتيب مختلف — القيم والمبالغ
   ما اتغيّرتش، والفواتير المقفولة بتتستبعد بعضويتها في
   `claim_invoices` مش بالتاريخ.

   يتطبّق على: السحابة (اتعمل 2026-10-28) **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── ١) الفواتير المفتوحة ─────────────────────────────────────── */
do $out$
declare def text;
begin
  select pg_get_functiondef('public.get_supplier_open_impl'::regproc) into def;

  def := replace(def,
E'    select h.pth_id, h.ven_bill_no, h.ven_bill_date::date d,\n           (h.total_bill - coalesce(h.total_des_mon,0))::numeric total\n      from purchase_invoices h\n     where h.branch=p_branch and h.ven_name_ar=p_vendor\n       and h.ven_bill_date::date > v_cut',
E'    select h.pth_id, h.ven_bill_no,\n           coalesce(h.sec_insert_date::date, h.ven_bill_date::date) d,\n           h.ven_bill_date::date inv_d,\n           (h.total_bill - coalesce(h.total_des_mon,0))::numeric total\n      from purchase_invoices h\n     where h.branch=p_branch and h.ven_name_ar=p_vendor\n       and coalesce(h.sec_insert_date::date, h.ven_bill_date::date) > v_cut');

  def := replace(def,
    E'\'invoices\', (select coalesce(jsonb_agg(jsonb_build_object(\'pth_id\',pth_id,\'bill_no\',ven_bill_no,\'date\',d,\'total\',total) order by d desc),\'[]\'::jsonb)',
    E'\'invoices\', (select coalesce(jsonb_agg(jsonb_build_object(\'pth_id\',pth_id,\'bill_no\',ven_bill_no,\'date\',d,\'inv_date\',inv_d,\'total\',total) order by d desc),\'[]\'::jsonb)');

  /* حارس: لو النسخة هنا مختلفة ومافيش replace اشتغل، نوقف بدل ما
     نسيب الدالة نص نص */
  if position('h.ven_bill_date::date d,' in def) > 0
     or position('''inv_date'',inv_d' in def) = 0 then
    raise exception 'تعريف get_supplier_open_impl مختلف — عدّله يدويًا';
  end if;
  execute def;
end $out$;

/* ── ٢) تفاصيل مطالبة مقفولة ─────────────────────────────────── */
do $out$
declare def text;
begin
  select pg_get_functiondef('public.get_claim_detail_impl'::regproc) into def;

  def := replace(def,
    E'\'invoices\', (select coalesce(jsonb_agg(jsonb_build_object(\'bill_no\',h.ven_bill_no,\'date\',h.ven_bill_date::date,\'total\',h.total_bill::numeric) order by h.ven_bill_date desc),\'[]\'::jsonb)',
    E'\'invoices\', (select coalesce(jsonb_agg(jsonb_build_object(\'bill_no\',h.ven_bill_no,\'date\',coalesce(h.sec_insert_date::date,h.ven_bill_date::date),\'inv_date\',h.ven_bill_date::date,\'total\',h.total_bill::numeric) order by coalesce(h.sec_insert_date,h.ven_bill_date) desc),\'[]\'::jsonb)');

  if position(E'\'date\',h.ven_bill_date::date,\'total\'' in def) > 0 then
    raise exception 'تعريف get_claim_detail_impl مختلف — عدّله يدويًا';
  end if;
  execute def;
end $out$;

/* ملاحظة: باقي الشاشات (المشتريات · مراجعة الصلاحيات · الفائض ·
   أفضل سعر شراء · قيمة بضاعة الفرع) لسه على `ven_bill_date` عن قصد —
   دي بتتكلم عن الفاتورة نفسها مش عن كشف حساب المورّد. */
