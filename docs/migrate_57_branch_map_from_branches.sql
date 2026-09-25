-- ═══════════════════════════════════════════════════════════════════
-- branch_map: من جدول ثابت لـview على جدول الفروع
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- ═══ العيب: أخطر فشل صامت فاضل في موضوع الفرع الرابع ═══
--
-- `branch_map` (اسم المخزن → اسم الفرع) كان **جدول ثابت بتلات صفوف**،
-- ومفيش شاشة بتكتب فيه، فالفرع الرابع عمره ما كان هيدخله.
--
-- والمشكلة إن **تسع دوال** بتعمل عليه `INNER JOIN`:
--   sales_summary · sales_by_day · sales_by_hour · sales_by_employee
--   sales_overview · sales_top_items · delivery_by_hour
--   delivery_active_days · get_kpi_dashboard
--
--   مثال من sales_summary:
--       join public.branch_map bm on bm.branch = rl.branch
--
--   يعني أول ما السيوف يبيع، مبيعاته ومرتجعاته **بتختفي من كل
--   تحليلات المبيعات ومن مؤشر الأداء**. مفيش خطأ ومفيش صفر — الفرع
--   مش موجود خالص، والتقرير يعرض تلات فروع ويبان طبيعي.
--
-- ═══ الحل الجذري ═══
-- الجدول بقى **view** على `branches`، فالتسع دوال بتشتغل من غير أي
-- تعديل فيها، وأي فرع جديد بيدخل التقارير لوحده.
--
-- أول اسم بديل (`aliases[1]`) هو اسم المخزن في eplus — نفس القاعدة
-- اللي `storeName()` في branches.js ماشية عليها. اتحقق إن ده بينتج
-- التلات صفوف القديمة **بصفر اختلاف**.
--
-- ⚠️ ليه view هنا مقبول رغم قاعدة «ممنوع view على جداول المخزون»:
--    القاعدة دي سببها إن مزامنة المخزون بتعمل rename/drop للجداول
--    والـview بيتسجّل كاعتماد ويوقف المزامنة. `branches` مش بيتعمله
--    rename ولا drop من أي مزامنة، فالسبب مش موجود هنا.
--
-- ⚠️ من غير فلتر `is_active` بالقصد: فرع متوقف لازم مبيعاته القديمة
--    تفضل ظاهرة في التقارير التاريخية.
--
-- ⚠️ صف واحد لكل فرع **بالضبط**: لو استعملنا كل الأسماء البديلة
--    (سان ليها اتنين) الـjoin كان هيضاعف الصفوف ويكبّر المجاميع.
--
-- التحقق على السحابة: ناتج الخمس دوال الرئيسية md5-مطابق قبل وبعد
--   (sales_summary 3 صفوف · sales_by_day 24 · sales_overview 1 ·
--    get_kpi_dashboard 1 · sales_top_items 20).
-- ═══════════════════════════════════════════════════════════════════

drop table if exists public.branch_map;

create or replace view public.branch_map as
  select coalesce(b.aliases[1], b.name) as store_name,
         b.name                          as branch
    from public.branches b
   where coalesce(b.aliases[1], b.name) is not null;

comment on view public.branch_map is
  'اسم المخزن في eplus → اسم الفرع. كان جدول ثابت بتلات صفوف، وكل الدوال '
  'بتعمل عليه INNER JOIN — فالفرع اللي مش فيه بتختفي مبيعاته من كل التقارير '
  'ومن مؤشر الأداء من غير أي خطأ. بقى view على branches: صف لكل فرع تلقائيًا. '
  'أول اسم بديل (aliases[1]) هو اسم المخزن — نفس القاعدة اللي storeName() '
  'في branches.js بتمشي عليها. '
  '⚠️ من غير فلتر is_active بالقصد: فرع متوقف لازم مبيعاته القديمة تفضل '
  'ظاهرة في التقارير التاريخية.';

grant select on public.branch_map to postgres, service_role, anon, authenticated;


-- ── إصلاح بيانات: save_as الفاضي لصف السيوف ─────────────────────
-- صف الربط اتعمل وقت إضافة الفرع بـapi_store بس، فـsave_as فضل فاضي.
update public.integration_branch_stores
   set save_as = 'السيوف',
       note    = coalesce(note,'') || 'اتظبط مع إضافة الفرع الرابع — save_as كان فاضي'
 where branch = 'السيوف' and (save_as is null or btrim(save_as) = '');


-- ── الفحص ────────────────────────────────────────────────────────
select store_name as اسم_المخزن, branch as الفرع from public.branch_map order by branch;
select branch, api_store, save_as from public.integration_branch_stores order by id;
