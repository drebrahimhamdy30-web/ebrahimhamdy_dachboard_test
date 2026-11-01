/* ═══════════════════════════════════════════════════════════════════
   تصحيح التكلفة: سعر الوحدة الصغرى بدل سعر العلبة
   ═══════════════════════════════════════════════════════════════════
   يكمّل `migrate_178`. الكمية في eplus بالوحدة الصغرى والسعر بالعلبة،
   فكل تكلفة كانت مضروبة في حجم العلبة:

     مستينون 60 مجم 150 قرص · سيدى بشر
       كان:  150 × 682.55  =  102,383 ج
       الصح: 150 ÷ 150 × 682.55 =  682.55 ج

   ── التعديل ─────────────────────────────────────────────────────
   ١. عمود `per_box` في الجدولين — بيتخزّن مع الصف، فالتصحيح الرجعي
      يبقى **قابل للتكرار بأمان**: بيشتغل على الصفوف اللي `per_box`
      فيها فاضي بس. من غيره تشغيل الترحيل مرتين كان هيقسم مرتين.
   ٢. المزامنتان بيقسموا على `itm_unit1_unit3` جوّه eplus — من غير
      جسر ومن غير استنتاج، نفس مفتاح الصف اللي جه منه السعر.
   ٣. تصحيح رجعي للصفوف الموجودة بنفس المعامل.

   ⚠️ `sell_price` في تعديلات المخزون بيتقسم هو كمان، عشان العمودين
      يفضلوا على نفس الأساس وما يحصلش نفس الفخ مرة تانية.
   ⚠️ `cost_value` عمود محسوب (`diff × cost_price`) فبيتصحّح لوحده.
   ⚠️ `qty` في الصلاحيات **بيفضل بالوحدة الصغرى** زي ما هو — تغييره
      كان هيكسر معنى السجل التاريخي `item_expiry_log`. العرض بالعلبة
      بيتحسب في الدالة: `qty / per_box`.

   الأثر المقاس قبل التطبيق (١٢ شهر، الأربع فروع):
     المعرّض:  2,501,850 → 1,086,681
     المُصفَّر:   157,384 →    64,940

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

alter table public.item_expiry      add column if not exists per_box numeric;
alter table public.stock_adjustments add column if not exists per_box numeric;

/* ── ١) تصحيح رجعي — الصفوف اللي لسه ما اتصحّحتش فقط ──────────── */
update public.item_expiry e
   set cost_total = case when e.cost_total is null then null
                         else round(e.cost_total / u.per_box, 4) end,
       per_box    = u.per_box
  from public.eplus_item_units u
 where u.itm_id::text = e.itm_code
   and e.per_box is null;

update public.stock_adjustments a
   set cost_price = case when a.cost_price is null then null
                         else round(a.cost_price / u.per_box, 4) end,
       sell_price = case when a.sell_price is null then null
                         else round(a.sell_price / u.per_box, 4) end,
       per_box    = u.per_box
  from public.eplus_item_units u
 where u.itm_id::text = a.itm_code
   and a.per_box is null;

/* الأصناف اللي مالهاش صف في الكتالوج: معاملها ١، نختمها عشان
   ما تتعادش تاني ولا تفضل مجهولة */
update public.item_expiry       set per_box = 1 where per_box is null;
update public.stock_adjustments set per_box = 1 where per_box is null;

/* ── ٢) مزامنة الصلاحيات: القسمة جوّه المصدر ──────────────────── */
update public.sync_jobs
   set steps = jsonb_build_array(jsonb_build_object(
         'select',
         'SELECT ''{branch}'' AS branch, t.itm_code, t.exp_date, t.qty,'
         || ' t.cost_total, t.last_buy, t.per_box FROM ('
         || 'SELECT s.itm_id AS itm_code,'
         || ' CONVERT(varchar(10), s.itm_expiry_date, 23) AS exp_date,'
         || ' SUM(s.itm_qty) AS qty,'
         /* ⚠️ القسمة قبل الضرب: الكمية بالوحدة الصغرى والسعر بالعلبة */
         || ' SUM(s.itm_qty / CASE WHEN ISNULL(c.itm_unit1_unit3,0) > 0'
         || ' THEN c.itm_unit1_unit3 ELSE 1 END * s.pharm_price) AS cost_total,'
         || ' MAX(s.sec_insert_date) AS last_buy,'
         || ' MAX(CASE WHEN ISNULL(c.itm_unit1_unit3,0) > 0'
         || ' THEN c.itm_unit1_unit3 ELSE 1 END) AS per_box'
         || ' FROM Item_Class_Store s'
         || ' LEFT JOIN Item_Catalog c ON c.itm_id = s.itm_id'
         || ' WHERE s.itm_qty > 0 AND s.itm_expiry_date IS NOT NULL'
         || ' AND s.itm_expiry_date >= GETDATE()'
         || ' AND s.itm_expiry_date < DATEADD(month, 36, GETDATE())'
         || ' AND s.sto_id = CASE ''{branch}'' WHEN ''mamora'' THEN 1'
         || ' WHEN ''san'' THEN 26 WHEN ''bishr'' THEN 28 WHEN ''seyouf'' THEN 29 END'
         || ' GROUP BY s.itm_id, s.itm_expiry_date) t',
         'target',   'item_expiry',
         'conflict', 'branch,itm_code,exp_date')),
       updated_at = now()
 where id = 'item_expiry';

/* ── ٣) مزامنة تعديلات المخزون: نفس القسمة ────────────────────── */
update public.sync_jobs
   set steps = jsonb_build_array(jsonb_build_object(
         'select',
         'SELECT ''{branch}'' AS branch, t.iqc_id, t.itm_code, t.sto_id, t.batch_id,'
         || ' t.old_qty, t.new_qty, t.exp_date, t.cost_price, t.sell_price,'
         || ' t.cause_id, t.cause, t.notes, t.ven_id, t.changed_at, t.changed_by, t.per_box'
         || ' FROM (SELECT q.iqc_id, q.iqc_itm_id AS itm_code, q.iqc_store_id AS sto_id,'
         || ' q.iqc_c_id AS batch_id, q.iqc_old_quantity AS old_qty,'
         || ' q.iqc_new_quantity AS new_qty,'
         || ' CONVERT(varchar(10), q.iqc_expiry, 23) AS exp_date,'
         || ' q.iqc_pharm_price / CASE WHEN ISNULL(c.itm_unit1_unit3,0) > 0'
         || ' THEN c.itm_unit1_unit3 ELSE 1 END AS cost_price,'
         || ' q.iqc_sell_price / CASE WHEN ISNULL(c.itm_unit1_unit3,0) > 0'
         || ' THEN c.itm_unit1_unit3 ELSE 1 END AS sell_price,'
         || ' CASE WHEN ISNULL(c.itm_unit1_unit3,0) > 0'
         || ' THEN c.itm_unit1_unit3 ELSE 1 END AS per_box,'
         || ' q.iqc_dc_id AS cause_id, d.dc_name_ar AS cause,'
         || ' q.iqc_notes AS notes, q.iqc_ven_id AS ven_id,'
         || ' q.sec_insert_date AS changed_at, q.sec_update_date AS updated_at,'
         || ' e.e_Name AS changed_by'
         || ' FROM Item_Quantity_Changes q'
         || ' LEFT JOIN Item_Catalog c ON c.itm_id = q.iqc_itm_id'
         || ' LEFT JOIN destroy_causes d ON d.dc_id = q.iqc_dc_id'
         || ' LEFT JOIN Employee e ON e.e_id ='
         || ' (CASE WHEN ISNUMERIC(q.sec_insert_uid)=1 THEN CAST(q.sec_insert_uid AS int) ELSE NULL END)'
         /* ⚠️ فلتر المخزن جوّه المصدر — راجع migrate_173 */
         || ' WHERE q.iqc_store_id = CASE ''{branch}'' WHEN ''mamora'' THEN 1'
         || ' WHEN ''san'' THEN 26 WHEN ''bishr'' THEN 28 WHEN ''seyouf'' THEN 29 END) t',
         'target',       'stock_adjustments',
         'conflict',     'branch,iqc_id',
         'probe_max',    'SELECT MAX(iqc_id) FROM Item_Quantity_Changes',
         'where_new',    't.iqc_id > {last_pth}',
         'where_window', '(t.changed_at >= ''{cut}'' OR t.updated_at >= ''{cut}'')')),
       updated_at = now()
 where id = 'stock_adjustments';

notify pgrst, 'reload schema';
