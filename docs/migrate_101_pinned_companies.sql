/* ═══════════════════════════════════════════════════════════════════
   شركاتي المتابَعة — شريط الشركات يعرض المختارة بس
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   شريط «كل شركة وكام صنف» طلّع **300 شركة** في طلبيات الكوزمو، أغلبها
   ذيل طويل بصنف أو اتنين. الشريط بقى حيطة نصّ بدل ما يكون أداة.

   ── القرار (المالك) ─────────────────────────────────────────────
   قائمة شركات يختارها المالك مرة واحدة وتتحفظ على السيرفر لكل
   المستخدمين، والشريط يعرضها هي بس. **والباقي يختفي خالص** —
   مفيش سطر مجمّع ولا زر «باقي N».

   ⚠️ يعني في الشريط مابيعبّرش عن كل المطلوب. الجدول تحته هو المرجع
      الكامل، والشريط أداة تنقّل للشركات اللي بتتعامل معاها فعلًا.

   ── ليه جدول مش عمود في org_settings ────────────────────────────
   القائمة بتكبر وبتتعدّل بالإضافة والحذف، وعايزين ترتيب ثابت للعرض.
   صف لكل شركة أسهل في الإدارة من مصفوفة jsonb بتتكتب كلها كل مرة.

   ── مفيش تصنيف في الجدول عن قصد ─────────────────────────────────
   الشاشة فيها 3 تبويبات (كوزمو · ورقيات · دوا) وشركات كل واحد
   مختلفة. بس القائمة **واحدة**: الشريط بيعرض المثبّتة اللي عندها
   أصناف في التبويب الحالي، فالشركة بتظهر لوحدها في مكانها الصح
   ومابتزحمش التبويبات التانية.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.pinned_companies (
  company    text primary key,
  sort_order int         not null default 0,
  updated_at timestamptz not null default now(),
  updated_by text
);

comment on table public.pinned_companies is
  'الشركات اللي بتظهر في شريط العدّادات في شاشات الطلبيات. فاضي = الشريط بيطلب من المستخدم يختار.';

alter table public.pinned_companies enable row level security;
revoke all on public.pinned_companies from anon, public;
drop policy if exists pinned_companies_auth on public.pinned_companies;
create policy pinned_companies_auth on public.pinned_companies
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.pinned_companies to authenticated;
grant all on public.pinned_companies to service_role;
