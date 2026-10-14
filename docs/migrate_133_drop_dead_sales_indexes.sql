/* ============================================================
   حذف ٤ فهارس ميتة على جداول بتتكتب بكثافة من المزامنات
   ------------------------------------------------------------
   كل فهرس زيادة بيتحدّث مع كل صف بيتكتب. sales_items (٢١٣ ألف صف)
   و store_item_prices (١٧٢ ألف صف) الاتنين بيتملوا بالجملة من
   المزامنات، فالفهرس اللي محدش بيقراه تكلفة صافية.

   المحذوفين (العدّادات من إنشاء القاعدة في مايو — مااتصفّرتش):
     store_item_prices_arnorm_idx  ١١ ميجا · صفر استعمال
     idx_sales_items_billno       ٦.٩ ميجا · ٣ استعمالات
     idx_sales_items_emp          ٣.١ ميجا · صفر استعمال
     idx_sales_items_itm          ٢.٥ ميجا · صفر استعمال

   ⚠️ الفحص اللي اتعمل قبل الحذف — مش العدّادات وبس:

   1) مفيش ولا نداء PostgREST مباشر على sales_items في أي شاشة؛ كل
      الوصول عن طريق دوال (sales_detail / sales_top_items / ...).

   2) store_item_prices_arnorm_idx مبني على **تعبير** ar_norm(item_name).
      فهرس التعبير مايتستعملش إلا لو الاستعلام مكتوب بنفس التعبير
      بالحرف — وفحص كل الدوال اللي بتلمس الجدول: ولا واحدة بتعمل كده.
      وPostgREST أصلًا مايقدرش يكتب تعبير في الفلتر.

   3) شغّلنا الدوال التقيلة فعلًا **قبل** الحذف، منها sales_detail
      بفلتر موظف حقيقي (السيناريو اللي idx_sales_items_emp اتعمل
      عشانه) — العدّادات فضلت صفر. الخطة بتختار idx_sales_items_date
      لأن كل استعلامات المبيعات محدودة بمدى تاريخ.

   4) «البحث برقم الفاتورة» في sales_detail مكتوب
      `bill_no ilike '%'||p_search||'%'` — النجمة في الأول بتمنع أي
      فهرس btree أصلًا. يعني idx_sales_items_billno ماكانش ينفع
      يخدم بحث الشاشة نفسه.

   القياس قبل/بعد على نفس البيانات:
     sales_detail (بفلتر موظف): 69 → 74 م.ث   (فرق ضوضاء)
     sales_price_review:         9 → 9  م.ث
     sales_discount_stats:      82 → 81 م.ث

   ⚠️ اللي اتأثّر فعلًا: البحث **المباشر** بصف واحد
     where bill_no = X  : 3.6 → 232 م.ث
     where itm_code = X : 2.6 → 47 م.ث
   ومفيش حاجة في النظام بتعمل كده (اتفحص). لو اتضاف فيلتر زي ده
   يومًا، السطور تحت بترجّع الفهرس في ثواني.

   الإرجاع عند الحاجة:
     create index concurrently idx_sales_items_billno on public.sales_items (bill_no);
     create index concurrently idx_sales_items_itm    on public.sales_items (itm_code);
     create index concurrently idx_sales_items_emp    on public.sales_items (employee_name);
     create index concurrently store_item_prices_arnorm_idx
       on public.store_item_prices (ar_norm(item_name));
   ============================================================ */
drop index concurrently if exists public.store_item_prices_arnorm_idx;
drop index concurrently if exists public.idx_sales_items_emp;
drop index concurrently if exists public.idx_sales_items_itm;
drop index concurrently if exists public.idx_sales_items_billno;
