-- migrate_123_current_shift_tabs.sql
-- تسجيل تبويبات شاشة «تفاصيل الشيفت الحالي» في نظام صلاحيات التبويبات (app_page_tabs)
-- عشان تظهر في شاشة الصلاحيات ويتحكّم فيها لكل دور، بدل الهاردكود في الشاشة.
-- كل نقطة بيع في الشاشة = تبويب: «نقطة البيع» (pos) و«كاشير» (cashier).
-- المنع افتراضي = مسموح؛ الأدمن دايمًا شايف الكل (get_role_tabs/guardTabs موجودين من migrate_22).
--
-- بذور المنع الافتراضي (قابلة للتغيير من شاشة الصلاحيات) مطابقة للمقصود:
--   الكاشير: يشوف «الكاشير» بس (ممنوع نقطة البيع)
--   الصيدلي/الدكتور (pharmacist): يشوف «نقطة البيع» بس (ممنوع الكاشير)

begin;

insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order) values
 ('current_shift','pos','نقطة البيع','#tabs .tab[data-tk="pos"]',1),
 ('current_shift','cashier','كاشير','#tabs .tab[data-tk="cashier"]',2)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

insert into public.tab_permissions (role, page_key, tab_key, allowed) values
 ('cashier','current_shift','pos',false),
 ('pharmacist','current_shift','cashier',false)
on conflict (role, page_key, tab_key) do update set allowed = excluded.allowed, updated_at = now();

commit;

notify pgrst, 'reload schema';
