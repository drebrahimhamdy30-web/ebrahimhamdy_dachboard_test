-- ════════════════════════════════════════════════════════════════════
-- استعلام عقدة n8n: «Upsert Sales Items1»  →  public.contract_invoices
-- النسخة المصحّحة (آخر تحديث 2026-10-06). انسخها كاملة مكان الاستعلام القديم.
-- الـqueryReplacement مايتغيّرش — نفس التسعة بنفس الترتيب:
--   [ bill_no, bill_date, cust_code, cust_name_ar, total_bill,
--     total_bill_net, employee_name, bill_status, store_name ]
--
-- اللي اتصلّح، وليه:
--  ١) الاستعلام القديم كان بينتهي بـ«;EXCLUDED.pos_status;» — عبارة
--     زيادة ملزوقة بعد الفاصلة المنقوطة. عقدة Postgres في n8n بتقسّم
--     الاستعلام على «;» وتنفّذ كل جزء، فالجزء التاني ده خطأ صياغة في
--     كل نبضة. اتشال.
--  ٢) الفروع كانت CASE مكتوب بالإيد — فرع جديد = تعديل العقدة.
--     بقت قراءة من branch_map (المشتقّة من جدول branches)، ودي
--     بالظبط نفس تطابق الأربع فروع الحالي، بس بتعرف الخامس لوحدها.
--     الملاذ coalesce(..., store_name) مقصود: لو المخزن مش معروف،
--     الصف **يتسجّل** باسم المخزن الخام ويبان غلط في فلتر الشاشة —
--     أحسن من إنه يختفي بالساكت.
--
-- ⚠️ **قرار المالك 2026-10-06: مفيش فلتر على حالة الفاتورة.**
--    كان فيه فلتر «Completed» لمدة قصيرة (أسوة بمسار sales_items)،
--    واتشال بناءً على طلبه: الفواتير **المحفوظة/غير المكتملة**
--    (bill_status = 'Pending' في eplus) لازم تدخل عادي عشان المحاسب
--    يشوفها ويقرّر بنفسه. ملاحظات مهمة على القرار ده:
--      • الفاتورة المحفوظة في eplus **مالهاش بنود**، فمش هتلاقيها في
--        `sales_items` خالص — أي تقرير بيطابق الجدولين لازم يتوقّع ده.
--      • الحالة بتتسجّل في العمود `pos_status`، وشاشتَي «التعاقدات»
--        و«المطالبات» بتعرضها كشارة «🟠 محفوظة» + فلتر مخصّص، عشان
--        ما تبقاش شكلها زي الفاتورة المكتملة.
-- ════════════════════════════════════════════════════════════════════
INSERT INTO public.contract_invoices
  (bill_no, bill_date, cust_code, cust_name_ar, total_bill, total_bill_net,
   employee_name, pos_status, branch, src_created_at)
SELECT v.bill_no, v.bill_date, v.cust_code, v.cust_name_ar,
       v.total_bill, v.total_bill_net, v.employee_name, v.pos_status,
       coalesce(bm.branch, v.store_name),
       now()
  FROM (
    SELECT $1::text                                               AS bill_no,
           NULLIF($2::text,'')::timestamp AT TIME ZONE 'Africa/Cairo' AS bill_date,
           $3::text                                               AS cust_code,
           $4::text                                               AS cust_name_ar,
           NULLIF($5::text,'')::numeric                           AS total_bill,
           NULLIF($6::text,'')::numeric                           AS total_bill_net,
           $7::text                                               AS employee_name,
           $8::text                                               AS pos_status,
           $9::text                                               AS store_name
  ) v
  LEFT JOIN public.branch_map bm ON bm.store_name = v.store_name
ON CONFLICT (bill_no, branch) DO UPDATE SET
  bill_date      = EXCLUDED.bill_date,
  cust_code      = EXCLUDED.cust_code,
  cust_name_ar   = EXCLUDED.cust_name_ar,
  total_bill     = EXCLUDED.total_bill,
  total_bill_net = EXCLUDED.total_bill_net,
  employee_name  = EXCLUDED.employee_name,
  pos_status     = EXCLUDED.pos_status;
