-- ═══════════════════════════════════════════════════════════════════
-- مخازن الفروع — فلتر صفوف رد eplus وتسمية المخزن
-- ═══════════════════════════════════════════════════════════════════
-- المشكلة اللي الجدول ده بيحلّها:
--   نداء فرع واحد على /api/Item/SearchItem بيرجّع الصنف في **كل** المخازن
--   اللي الفرع شايفها، لكن البيانات الصحيحة هي بتاعة الفرع اللي بنسحب منه
--   بس — الباقي انعكاس مش موثوق.
--
--   والأخطر: itm_code **مش مفتاح فريد**. اختبار حقيقي على المعمورة رجّع
--   الصنف sr10 تلات مرات في صفحة واحدة:
--       ابراهيم حمدي 3 → 112
--       الصيدلية       → 228      ← ده الصح
--       ابراهيم حمدي 2 → 398.82
--   يعني upsert بمفتاح itm_code لوحده بيخلّي آخر صف يكتب فوق الباقي،
--   والشاشة توريك 398.82 بدل 228 — **بيانات غلط من غير أي رسالة خطأ**.
--
--   الأرقام بتأكّد إن n8n بيفلتر على «الصيدلية» من الأصل:
--       eplus يرجّع  : 60,809 صف (كل المخازن)
--       «الصيدلية»   : 27,270
--       stock_mamora : 27,270   ← مطابق بالظبط
--
-- unique(branch, api_store): الفرع يقدر يكون له أكتر من مخزن مطلوب.
--
-- ⚠️ فرع مالوش صف هنا = **مابيتفلترش** (بيتخزّن بكل مخازنه زي ما هو).
--    القرار ده مقصود عشان إضافة الجدول ماتكسرش نقاط شغّالة قبل ما يتملا.
--
-- ⚠️ قيمة branch لازم تطابق **مفتاح EPLUS_BRANCHES** بالحرف، مش الاسم
--    المعروض في الشاشة. لو اختلفوا، الفلتر مش هيلاقي الفرع ومش هيشتغل.
--
-- ⚠️ يتشغّل على **الاتنين**: سحابة rxtjoqulmgkkcohmgzgi + سيرفر
--    supabase.ebrahimhamdy.com — القاعدتين لازم يفضلوا متطابقين.
--    (اتطبّق على السحابة 2026-09-13.)
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.integration_branch_stores (
  id         bigint generated always as identity primary key,
  branch     text    not null,
  api_store  text    not null,
  save_as    text,
  is_active  boolean not null default true,
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (branch, api_store)
);

comment on column public.integration_branch_stores.branch    is 'اسم الفرع زي ما هو في EPLUS_BRANCHES';
comment on column public.integration_branch_stores.api_store is 'قيمة sto_name الجاية من الـAPI';
comment on column public.integration_branch_stores.save_as   is 'الاسم اللي يتخزّن في الجدول الهدف — فاضي = يتخزّن زي ما هو';

alter table public.integration_branch_stores enable row level security;

-- نفس حماية integration_endpoints بالظبط: authenticated بس، وanon مقفول
drop policy if exists ibs_read  on public.integration_branch_stores;
drop policy if exists ibs_write on public.integration_branch_stores;
create policy ibs_read  on public.integration_branch_stores for select to authenticated using (true);
create policy ibs_write on public.integration_branch_stores for all    to authenticated using (true) with check (true);

grant select, insert, update, delete on public.integration_branch_stores to authenticated;
grant all on public.integration_branch_stores to service_role;
revoke all on public.integration_branch_stores from anon;

-- ── الماب: مصدره النظام نفسه مش تخمين ──────────────────────────────
-- v_stock_units_full كانت بتكتب الأسماء دي **صريح في الكود**:
--     stock_mamora → 'الصيدلية'          (المعمورة)
--     stock_san    → 'ابراهيم حمدي 2'    (سان ستيفانو)
--     stock_bishr  → 'ابراهيم حمدي 3'    (سيدى بشر)
--
-- وده بيفسّر عيّنة الصفحة ٢ من اختبار المعمورة: الصنف sr10 رجع بتلات
-- أرصدة (112 / 228 / 398.82) — مش تلات مخازن جوّه فرع، دول **التلات
-- فروع** كلهم باينين من نداء فرع واحد. الصح للمعمورة هو 228 بس.
--
-- save_as = اسم الفرع: الصفحات تتعامل مع اسم الفرع مباشرة من غير
-- تحويل ولا أسماء مكتوبة في الكود.
--
-- ⚠️ المعمورة متأكَّد منها بالأرقام (27,270 = stock_mamora).
--    الفرعين التانيين مصدرهم الـview القديمة — يتأكدوا باختبار نقطة
--    item بعد تغيير الفرع من أعلى الشاشة.
insert into public.integration_branch_stores (branch, api_store, save_as, note) values
  ('المعمورة',     'الصيدلية',       'المعمورة',     'المصدر: v_stock_units_full + اختبار نقطة item (27,270 = stock_mamora)'),
  ('سان ستيفانو',  'ابراهيم حمدي 2', 'سان ستيفانو',  'المصدر: v_stock_units_full — محتاج تأكيد باختبار الفرع'),
  ('سيدى بشر',     'ابراهيم حمدي 3', 'سيدى بشر',     'المصدر: v_stock_units_full — محتاج تأكيد باختبار الفرع')
on conflict (branch, api_store) do update
  set save_as = excluded.save_as, note = excluded.note, updated_at = now();

select branch as الفرع, api_store as مخزن_الـAPI,
       coalesce(save_as, '(زي ما هو)') as يتخزّن_باسم, is_active as مفعّل
from public.integration_branch_stores order by branch, api_store;
