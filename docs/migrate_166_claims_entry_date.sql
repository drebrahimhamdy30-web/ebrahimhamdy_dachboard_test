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


/* ════════════════════════════════════════════════════════════════
   ١٦٦-ب · توحيد الأساس على كل شاشات المشتريات (2026-10-28)
   ----------------------------------------------------------------
   المالك: «اعتمادي كله على تاريخ الإدخال». فكل مكان بيستعمل تاريخ
   الفاتورة كـ**تاريخ عرض أو فلترة** اتحوّل لـ
   `coalesce(sec_insert_date, ven_bill_date)`:

     • get_supplier_report_impl          (تقرير المورّد)
     • get_supplier_balance_review_impl  (مراجعة الأرصدة)
     • get_purchases_impl                (المشتريات: فلتر+ترتيب+عرض)
     • get_purchase_expiry_review_impl   (مراجعة الصلاحيات)
     • get_purchase_returns              (مرتجعات الشراء)
     • get_purchase_order_review_impl    (مراجعة أوامر الشراء: الفلاتر والعرض)
     • get_purchase_surplus_return_impl  (الفائض: الفلتر)

   ⚠️ **اللي اتساب عن قصد** — دي مش تواريخ عرض، دي منطق أرقام:
     • ترتيب `array_agg(... order by pih.ven_bill_date desc)` في
       الفائض — بيختار «آخر سعر شراء».
     • `refresh_best_purchase` و`search_item_cost` و`value_branch_goods` —
       اختيار أحدث سعر وتقييم البضاعة.
     تغيير دول بيحرّك تكلفة أصناف وتقييم مخزون، فمحتاج قرار منفصل.
   ════════════════════════════════════════════════════════════════ */

do $out$
declare def text;
begin
  select pg_get_functiondef('public.get_supplier_report_impl'::regproc) into def;
  def := replace(def, '(h.ven_bill_date)::date as d,',
                      'coalesce(h.sec_insert_date, h.ven_bill_date)::date as d,');
  def := replace(def, 'where (h.ven_bill_date)::date between p_from and p_to',
                      'where coalesce(h.sec_insert_date, h.ven_bill_date)::date between p_from and p_to');
  if position('(h.ven_bill_date)::date' in def) > 0 then
    raise exception 'supplier_report: تعريف مختلف — عدّله يدويًا';
  end if;
  execute def;

  select pg_get_functiondef('public.get_supplier_balance_review_impl'::regproc) into def;
  def := replace(def, 'and h.ven_bill_date::date > coalesce(cuts.cut, ''-infinity''::date)',
                      'and coalesce(h.sec_insert_date, h.ven_bill_date)::date > coalesce(cuts.cut, ''-infinity''::date)');
  execute def;

  select pg_get_functiondef('public.get_purchases_impl'::regproc) into def;
  def := replace(def, 'and (p_from is null or h.ven_bill_date >= p_from)',
                      'and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date) >= p_from)');
  def := replace(def, 'and (p_to is null or h.ven_bill_date < p_to + 1)',
                      'and (p_to is null or coalesce(h.sec_insert_date, h.ven_bill_date) < p_to + 1)');
  def := replace(def, 'select h.branch, h.pth_id, h.ven_bill_no, h.ven_bill_date, h.ven_name_ar, h.sto_id, h.store_name,',
                      'select h.branch, h.pth_id, h.ven_bill_no, coalesce(h.sec_insert_date, h.ven_bill_date) ven_bill_date, h.ven_name_ar, h.sto_id, h.store_name,');
  def := replace(def, 'order by h.ven_bill_date desc nulls last, h.pth_id desc',
                      'order by coalesce(h.sec_insert_date, h.ven_bill_date) desc nulls last, h.pth_id desc');
  if position('h.ven_bill_date >= p_from' in def) > 0 then raise exception 'purchases: تعريف مختلف'; end if;
  execute def;

  select pg_get_functiondef('public.get_purchase_expiry_review_impl'::regproc) into def;
  def := replace(def, 'select pi.branch, pi.pth_id, h.ven_name_ar, h.ven_bill_date, h.entered_by,',
                      'select pi.branch, pi.pth_id, h.ven_name_ar, coalesce(h.sec_insert_date, h.ven_bill_date) ven_bill_date, h.entered_by,');
  def := replace(def, 'and (p_from is null or h.ven_bill_date >= p_from)',
                      'and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date) >= p_from)');
  def := replace(def, 'and (p_to is null or h.ven_bill_date < p_to + 1)',
                      'and (p_to is null or coalesce(h.sec_insert_date, h.ven_bill_date) < p_to + 1)');
  if position('h.ven_bill_date >= p_from' in def) > 0 then raise exception 'expiry: تعريف مختلف'; end if;
  execute def;

  select pg_get_functiondef('public.get_purchase_returns'::regproc) into def;
  def := replace(def, 'pb.ven_bill_date::date  bill_date,',
                      'coalesce(pb.sec_insert_date, pb.ven_bill_date)::date  bill_date,');
  def := replace(def, 'h.ven_bill_date::date ret_date,',
                      'coalesce(h.sec_insert_date, h.ven_bill_date)::date ret_date,');
  def := replace(def, 'h.ven_bill_date::date bill_date,',
                      'coalesce(h.sec_insert_date, h.ven_bill_date)::date bill_date,');
  def := replace(def, 'and (p_from is null or h.ven_bill_date::date >= p_from)',
                      'and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date)::date >= p_from)');
  def := replace(def, 'and (p_to   is null or h.ven_bill_date::date <= p_to)',
                      'and (p_to   is null or coalesce(h.sec_insert_date, h.ven_bill_date)::date <= p_to)');
  if position('h.ven_bill_date::date >= p_from' in def) > 0 then raise exception 'returns: تعريف مختلف'; end if;
  execute def;

  select pg_get_functiondef('public.get_purchase_order_review_impl'::regproc) into def;
  def := replace(def, 'select h.branch, h.pth_id, h.ven_name_ar, h.ven_bill_date, h.entered_by,',
                      'select h.branch, h.pth_id, h.ven_name_ar, coalesce(h.sec_insert_date, h.ven_bill_date) ven_bill_date, h.entered_by,');
  def := replace(def, 'select h.branch, h.pth_id, h.ven_bill_date, h.ven_name_ar,',
                      'select h.branch, h.pth_id, coalesce(h.sec_insert_date, h.ven_bill_date) ven_bill_date, h.ven_name_ar,');
  def := replace(def, 'and (p_from is null or h.ven_bill_date >= p_from)',
                      'and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date) >= p_from)');
  def := replace(def, 'and (p_to is null or h.ven_bill_date < p_to + 1)',
                      'and (p_to is null or coalesce(h.sec_insert_date, h.ven_bill_date) < p_to + 1)');
  def := replace(def, 'and (p_from is null or h.ven_bill_date >= p_from)',
                      'and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date) >= p_from)');
  def := replace(def, 'and (p_to is null or h.ven_bill_date < p_to + 1)',
                      'and (p_to is null or coalesce(h.sec_insert_date, h.ven_bill_date) < p_to + 1)');
  def := replace(def, 'and (p_from is null or h.ven_bill_date >= p_from)',
                      'and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date) >= p_from)');
  def := replace(def, 'and (p_to is null or h.ven_bill_date < p_to + 1)',
                      'and (p_to is null or coalesce(h.sec_insert_date, h.ven_bill_date) < p_to + 1)');
  execute def;

  select pg_get_functiondef('public.get_purchase_surplus_return_impl'::regproc) into def;
  def := replace(def, '|| ''      and ($3 is null or pih.ven_bill_date::date >= $3)''',
                      '|| ''      and ($3 is null or coalesce(pih.sec_insert_date, pih.ven_bill_date)::date >= $3)''');
  def := replace(def, '|| ''      and ($4 is null or pih.ven_bill_date::date <= $4)''',
                      '|| ''      and ($4 is null or coalesce(pih.sec_insert_date, pih.ven_bill_date)::date <= $4)''');
  execute def;
end $out$;


/* ════════════════════════════════════════════════════════════════
   ١٦٦-ج · ربط الفاتورة بطلبيتها يمشي على تاريخ الإدخال (2026-10-28)
   ----------------------------------------------------------------
   شاشة «مراجعة أوامر الشراء» بتجاوب: الطلبية اللي بعتناها للمورّد
   وصل منها إيه؟ وعشان تعرف الفاتورة دي من أنهي طلبية، بتدوّر على
   **آخر طلبية اتبعتت للمورّد قبل الفاتورة** (`supplier_links.applied_at`).

   كانت المقارنة بتاريخ فاتورة المورّد، فالفاتورة اللي المورّد كاتب
   عليها تاريخ أقدم من يوم التسليم كانت تبان «وصلت من غير طلب»
   والطلبية تبان «طلبنا ومجاش» — وهما نفس الحاجة.

   الفاتورة بتتسجّل ساعة ما البضاعة توصل الصيدلية، والطلبية اتبعتت
   قبل الوصول — فتاريخ الإدخال أقرب للواقع في المطابقة دي.

   الأثر المقاس قبل التطبيق: من ٦٤٤٩ فاتورة في آخر ٩٠ يوم، **٤٩
   فاتورة** بس هي اللي بتترابط بطلبية مختلفة (أقل من ١٪)، وواحدة
   كانت بلا طلبية وبقت مترابطة.
   ════════════════════════════════════════════════════════════════ */

do $out$
declare def text; n int;
begin
  select pg_get_functiondef('public.get_purchase_order_review_impl'::regproc) into def;
  def := replace(def, 'sl.applied_at::date <= h.ven_bill_date::date',
                      'sl.applied_at::date <= coalesce(h.sec_insert_date, h.ven_bill_date)::date');
  select count(*) into n from regexp_matches(def, 'applied_at::date <= h\.ven_bill_date', 'g');
  if n > 0 then raise exception 'order_review: فاضل % شرط قديم', n; end if;
  execute def;
end $out$;
