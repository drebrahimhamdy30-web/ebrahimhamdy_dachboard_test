/* ═══════════════════════════════════════════════════════════════════
   تقييم العملاء: الشاشة وكل تبويباتها للأدمن فقط (مرحلة التجربة)
   ═══════════════════════════════════════════════════════════════════
   migrate_152 فتح العرض للمدير والصيدلي والمشرف وتبويب الترتيب للكل.
   قرار المالك (2026-10-18): حاليًا الأدمن بس يشوف الشاشة وتبويباتها
   الأربعة، ولما يقرر يفتحها للصيادلة يعملها من شاشة الصلاحيات
   (الصفحة والتبويبات ظاهرين هناك) — مش بترحيل جديد.

   الصفوف بتتكتب صراحةً (مش بتتمسح) عشان شاشة الصلاحيات تعرض الحالة
   الحقيقية لكل دور، ولأن «مفيش صف في tab_permissions = مسموح».

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

begin;

insert into public.page_permissions (role, page, can_view, can_edit)
select r, 'ratings.html', (r = 'admin'), (r = 'admin')
  from unnest(array['admin','manager','pharmacist','supervisor','employee','cashier','accountant','inventory','reviewer']) r
on conflict (role, page) do update set can_view = excluded.can_view, can_edit = excluded.can_edit;

insert into public.tab_permissions (role, page_key, tab_key, allowed)
select r, 'ratings', t, false
  from unnest(array['manager','pharmacist','supervisor','employee','cashier','accountant','inventory','reviewer']) r,
       unnest(array['rank','comments','links','settings']) t
on conflict (role, page_key, tab_key) do update set allowed = false, updated_at = now();

commit;
