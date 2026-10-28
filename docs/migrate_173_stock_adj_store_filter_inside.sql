/* ═══════════════════════════════════════════════════════════════════
   إصلاح: فرع المعمورة سحب حركات الفروع كلها
   ═══════════════════════════════════════════════════════════════════
   ── العطل ────────────────────────────────────────────────────────
   `migrate_171` حطّ فلتر المخزن في `where_new`/`where_window` بس.
   أول تحميل للمعمورة اتنفّذ **من غير الفلتر ده خالص**: الجدول كله
   39,780 صف (من 2015) اتختم `branch='mamora'`، منهم **6,374 صف
   بتاع فروع تانية** (سان 6,086 · بشر 176 · مخزن 24 بـ94 · السيوف 16).
   الفروع التلاتة التانية طلعت نضيفة، يعني الفلتر اتطبّق عليهم —
   فالمحرّك بيتخطّى `where_*` في مسار التحميل الأول/الكامل.

   الرقم اللي كشفها: `MIN(changed_at)` للمعمورة طلع **2015-12-13**،
   ومجموع صفوف المعمورة ساوى بالظبط عدد صفوف الجدول كله في eplus.

   ── الإصلاح ─────────────────────────────────────────────────────
   الفلتر اتنقل **جوّه الـSELECT نفسه** في جدول مشتق — نفس أسلوب
   `item_expiry` اللي شغّال صح من يوم واحد. كده مفيش مسار في
   المحرّك يقدر يتخطّاه، و`where_new`/`where_window` بقت شروط
   نضيفة على `t` بس.

   ⚠️ الدرس: **فلتر الفرع مايتحطّش في شرط اختياري** — يتحط في
   مصدر البيانات نفسه. أي شرط المحرّك ممكن يسيبه = بيانات فرع
   في فرع تاني. راجع [[safe-fallback-turns-unsafe]] و
   [[sync-jobs-branch-code]].

   العلامة المائية (`last_pth`) تفضل زي ما هي: `iqc_id` رقم عام
   تصاعدي مشترك بين المخازن، فأعلى رقم اتشاف علامة صحيحة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) تنضيف الصفوف المتسرّبة ─────────────────────────────────── */
delete from public.stock_adjustments a
 where a.sto_id is distinct from
       (case a.branch when 'mamora' then 1 when 'san' then 26
                      when 'bishr'  then 28 when 'seyouf' then 29 end);

/* ── 2) الفلتر جوّه المصدر ──────────────────────────────────────── */
update public.sync_jobs
   set steps = jsonb_build_array(jsonb_build_object(
         'select',
         'SELECT ''{branch}'' AS branch, t.iqc_id, t.itm_code, t.sto_id, t.batch_id,'
         || ' t.old_qty, t.new_qty, t.exp_date, t.cost_price, t.sell_price,'
         || ' t.cause_id, t.cause, t.notes, t.ven_id, t.changed_at, t.changed_by'
         || ' FROM (SELECT q.iqc_id, q.iqc_itm_id AS itm_code, q.iqc_store_id AS sto_id,'
         || ' q.iqc_c_id AS batch_id, q.iqc_old_quantity AS old_qty,'
         || ' q.iqc_new_quantity AS new_qty,'
         || ' CONVERT(varchar(10), q.iqc_expiry, 23) AS exp_date,'
         || ' q.iqc_pharm_price AS cost_price, q.iqc_sell_price AS sell_price,'
         || ' q.iqc_dc_id AS cause_id, d.dc_name_ar AS cause,'
         || ' q.iqc_notes AS notes, q.iqc_ven_id AS ven_id,'
         || ' q.sec_insert_date AS changed_at, q.sec_update_date AS updated_at,'
         || ' e.e_Name AS changed_by'
         || ' FROM Item_Quantity_Changes q'
         || ' LEFT JOIN destroy_causes d ON d.dc_id = q.iqc_dc_id'
         || ' LEFT JOIN Employee e ON e.e_id ='
         || ' (CASE WHEN ISNUMERIC(q.sec_insert_uid)=1 THEN CAST(q.sec_insert_uid AS int) ELSE NULL END)'
         /* ⚠️ الفلتر هنا بالذات — مش في شرط اختياري */
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
