/* ═══════════════════════════════════════════════════════════════════
   حركات تعديل المخزون من eplus — مصدر «كام اتلف فعلًا»
   ═══════════════════════════════════════════════════════════════════
   ── التصحيح اللي أوصل لده ───────────────────────────────────────
   كنت استنتجت إن التلف شبه معدوم، لأن الدفعات اللي انتهت رصيدها
   صفر. **المالك صحّح: الأرصدة دي بتتصفّر يدويًا على السيستم** —
   فالصفر معناه **اتشالت**، مش اتباعت. استنتاجي كان مقلوب.

   ── المصدر الصح ─────────────────────────────────────────────────
   `Item_Quantity_Changes` في Genius (39,778 سجل) بيسجّل كل تعديل
   كمية: الكمية قبل وبعد · الدفعة · الصلاحية · **سعر التكلفة وقت
   الحركة** · السبب · الملاحظة · المورّد · مين عملها وإمتى.
   و`destroy_causes` فيه 9 أسباب:
     تالف · **منتهى صلاحية** · خطأ جرد · سرقة · فرق كسور ·
     شراء كسور · عجز · زيادة · شراء

   ── المقاس (آخر 7 شهور، الأربع فروع) ───────────────────────────
     بدون سبب        932,158ج   ← أكبر بند، ومحدش كاتب ليه
     خطأ جرد         850,991ج
     منتهى صلاحية     86,862ج   ← ده اللي بندوّر عليه
     سرقة             17,500ج   (حركة واحدة)
     عجز               8,289ج
     تالف              3,460ج
     زيادة         (1,093,233ج) إضافة للمخزون

   و«منتهى صلاحية» شهريًا مش خط منتظم — قفزات (يوليو 27 ألف،
   سبتمبر 40 ألف) وشهور شبه فاضية. الأرجح إن التصفير بيتعمل على
   دفعات لما حد ينضّف، مش أول بأول — فالشهر الفاضي **مش** معناه
   مفيش تلف.

   ⚠️ `iqc_pharm_price` تكلفة مسجّلة **وقت الحركة**، يعني رقم حقيقي
      مش تقدير، وبنفس وحدة الكمية.
   ⚠️ `itm_code` هنا **itm_id خام** زي كل مزامنات SQL المباشر —
      بيتحل بجسر `eplus_id_code`. راجع [[eplus-itmid-code-bridge]].

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.stock_adjustments (
  branch      text   not null,
  iqc_id      bigint not null,
  itm_code    text,                -- itm_id خام من eplus
  sto_id      int,
  batch_id    int,
  old_qty     numeric,
  new_qty     numeric,
  exp_date    date,
  cost_price  numeric,
  sell_price  numeric,
  cause_id    int,
  cause       text,
  notes       text,
  ven_id      int,
  changed_at  timestamp,
  changed_by  text,
  synced_at   timestamptz not null default now(),
  /* موجب = اتشال من المخزون · سالب = اتضاف */
  diff        numeric generated always as (coalesce(old_qty,0) - coalesce(new_qty,0)) stored,
  cost_value  numeric generated always as
                ((coalesce(old_qty,0) - coalesce(new_qty,0)) * coalesce(cost_price,0)) stored,
  primary key (branch, iqc_id)
);

comment on table public.stock_adjustments is
  'تعديلات كميات المخزون من eplus (Item_Quantity_Changes) بسببها — مصدر «كام اتلف ومنتهي الصلاحية فعلًا». الأرصدة بتتصفّر يدويًا فالصفر مش بيع.';

create index if not exists stock_adj_month_idx on public.stock_adjustments (changed_at, branch);
create index if not exists stock_adj_cause_idx on public.stock_adjustments (cause_id, changed_at);
create index if not exists stock_adj_item_idx  on public.stock_adjustments (itm_code, branch);

/* ⚠️ الجداول اللي بتتعمل بترحيل مابتاخدش صلاحيات كتابة تلقائيًا —
   ودي اللي كسرت مزامنة الصلاحيات في migrate_170. */
grant select on public.stock_adjustments to authenticated;
grant select, insert, update on public.stock_adjustments to service_role;

/* ── المزامنة ───────────────────────────────────────────────────── */
insert into public.sync_jobs
  (id, name, source_db, enabled, interval_minutes, window_days, window_refresh_minutes, sort_order, steps)
values (
  'stock_adjustments', 'تعديلات المخزون (إتلاف/جرد)', 'Genius', true,
  60,   -- كل ساعة؛ الحركات دي مش لحظية
  14, 1, 80,
  jsonb_build_array(jsonb_build_object(
    'select',
    'SELECT ''{branch}'' AS branch, q.iqc_id, q.iqc_itm_id AS itm_code,'
    || ' q.iqc_store_id AS sto_id, q.iqc_c_id AS batch_id,'
    || ' q.iqc_old_quantity AS old_qty, q.iqc_new_quantity AS new_qty,'
    || ' CONVERT(varchar(10), q.iqc_expiry, 23) AS exp_date,'
    || ' q.iqc_pharm_price AS cost_price, q.iqc_sell_price AS sell_price,'
    || ' q.iqc_dc_id AS cause_id, d.dc_name_ar AS cause,'
    || ' q.iqc_notes AS notes, q.iqc_ven_id AS ven_id,'
    || ' q.sec_insert_date AS changed_at, e.e_Name AS changed_by'
    || ' FROM Item_Quantity_Changes q'
    || ' LEFT JOIN destroy_causes d ON d.dc_id = q.iqc_dc_id'
    || ' LEFT JOIN Employee e ON e.e_id ='
    || ' (CASE WHEN ISNUMERIC(q.sec_insert_uid)=1 THEN CAST(q.sec_insert_uid AS int) ELSE NULL END)',
    'target',       'stock_adjustments',
    'conflict',     'branch,iqc_id',
    'probe_max',    'SELECT MAX(iqc_id) FROM Item_Quantity_Changes',
    /* ⚠️ فلتر المخزن إلزامي: سيرفر الماستر فيه بيانات المخازن
       الأربعة، فمن غيره كل فرع كان هيسحب حركات الفروع التانية
       ويختمها باسمه. نفس أسلوب مزامنة تواريخ الصلاحية. */
    'where_new',    'q.iqc_store_id = CASE ''{branch}'' WHEN ''mamora'' THEN 1 WHEN ''san'' THEN 26'
                    || ' WHEN ''bishr'' THEN 28 WHEN ''seyouf'' THEN 29 END AND q.iqc_id > {last_pth}',
    'where_window', 'q.iqc_store_id = CASE ''{branch}'' WHEN ''mamora'' THEN 1 WHEN ''san'' THEN 26'
                    || ' WHEN ''bishr'' THEN 28 WHEN ''seyouf'' THEN 29 END'
                    || ' AND (q.sec_insert_date >= ''{cut}'' OR q.sec_update_date >= ''{cut}'')')))
on conflict (id) do update
  set name = excluded.name, steps = excluded.steps, enabled = true,
      interval_minutes = excluded.interval_minutes,
      window_days = excluded.window_days,
      window_refresh_minutes = excluded.window_refresh_minutes,
      updated_at = now();

/* ⚠️ صفوف الحالة لكل فرع إلزامية — من غيرها المحرّك مايعرفش يشغّل
   المهمة والطلب يفضل pending بلا أي خطأ. */
insert into public.sync_branch_state (job_id, branch, enabled, last_pth)
select 'stock_adjustments', b, true, 0
  from unnest(array['mamora','san','bishr','seyouf']) b
on conflict (job_id, branch) do nothing;

notify pgrst, 'reload schema';
