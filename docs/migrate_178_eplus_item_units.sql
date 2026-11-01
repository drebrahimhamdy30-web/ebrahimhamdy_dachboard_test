/* ═══════════════════════════════════════════════════════════════════
   أحجام العبوات من eplus — مُعامل تحويل الوحدة الصغرى إلى علبة
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   `Item_Class_Store.itm_qty` بيتسجّل **بأصغر وحدة** (قرص/وحدة/قطعة)،
   و`pharm_price` **سعر العلبة**. فضرب الاتنين في بعض بيطلع رقمًا
   مضروبًا في حجم العلبة. دفعة «مستينون ١٥٠ قرص» (علبة واحدة بـ٦٨٢ج)
   كانت بتظهر في شاشة الصلاحيات بـ**١٠٢,٣٨٣ج**.

   ── العمود الصح: itm_unit1_unit3 مش itm_unit1_unit2 ──────────────
   الصنف في eplus له **تلات مستويات** مش اتنين: علبة ← شريط ← وحدة.
     `itm_unit1_unit2` = علبة ← شريط   (المتوسط)
     `itm_unit1_unit3` = علبة ← وحدة   (الأصغر)  ← ده الصح
   «اتروفينت 500ملى 20فيال»: العلبة ٢ شريط و٢٠ وحدة، والمخزون
   بيسجّل **47** — يعني بالوحدة. لو قسمنا على ٢ بدل ٢٠ كان ٥٢ دفعة
   هتفضل أعلى من الحقيقة بعشر أضعاف (٩٢ ألف جنيه).

   ── التأكيد من قناة تانية ────────────────────────────────────────
   جداول `branch_stock*` الجاية من **API المخزون** (مفتاحها كودنا، مش
   itm_id) فيها `unit_big_small_coeff`. قارنّا ٤٠ صنف: **٣٨ اتطابقوا
   و٠ اختلفوا** (اتنين مالهمش كود في الجسر). المصدران متفقان.

   ⚠️ بناخد المعامل من **eplus** مش من الـAPI، لأن مزامنة الصلاحيات
      والتعديلات بتشتغل جوّه eplus على `itm_id`. لو جبناه من جدول
      الـAPI هنحتاج جسر `eplus_id_code` فنرجّع الاستنتاج لمعادلة
      كانت خالية منه. جدول الـAPI يفضل **المرجع اللي نقارن بيه**.

   ⚠️ صنفان في الكتالوج معاملهم صفر/فاضي — بيتحوّلوا لـ١.
      والمدى من ١ لـ١٠٠٠، فالقسمة آمنة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.eplus_item_units (
  itm_id    bigint primary key,
  per_box   numeric not null,        -- كام وحدة صغرى في العلبة
  synced_at timestamptz not null default now()
);

comment on table public.eplus_item_units is
  'معامل تحويل الوحدة الصغرى إلى علبة لكل صنف في eplus (itm_unit1_unit3). الكمية في المخزون بالوحدة الصغرى والسعر بالعلبة، فالتكلفة = كمية ÷ per_box × سعر العلبة.';

grant select on public.eplus_item_units to authenticated;
/* ⚠️ الجداول اللي بتتعمل بترحيل مابتاخدش صلاحية كتابة تلقائيًا */
grant select, insert, update on public.eplus_item_units to service_role;

/* ── المزامنة: لقطة كاملة يوميًا (٣١ ألف صف، الجدول صغير) ──────── */
insert into public.sync_jobs
  (id, name, source_db, enabled, interval_minutes, window_days, window_refresh_minutes, sort_order, steps)
values (
  'eplus_item_units', 'أحجام العبوات', 'Genius', true, 1440, 0, 0, 85,
  jsonb_build_array(jsonb_build_object(
    'select',
    'SELECT itm_id, CASE WHEN ISNULL(itm_unit1_unit3,0) > 0'
    || ' THEN itm_unit1_unit3 ELSE 1 END AS per_box FROM Item_Catalog',
    'target',   'eplus_item_units',
    'conflict', 'itm_id')))
on conflict (id) do update
  set name = excluded.name, steps = excluded.steps, enabled = true,
      interval_minutes = excluded.interval_minutes, updated_at = now();

/* ⚠️ من غير صف الحالة المهمة بتفضل pending بلا أي خطأ.
   الكتالوج مشترك على الماستر، ففرع واحد يكفي. */
insert into public.sync_branch_state (job_id, branch, enabled, last_pth)
values ('eplus_item_units', 'mamora', true, 0)
on conflict (job_id, branch) do nothing;

notify pgrst, 'reload schema';
