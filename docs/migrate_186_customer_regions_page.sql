-- migrate_186_customer_regions_page.sql
-- تسجيل شاشة «تعيين مناطق العملاء» فى الملاحة والصلاحيات.
-- بدونها الشاشة مخفية/محجوبة صامتة (page_permissions.can_view).
-- مُطبّق على السحابة 2026-10-31. للذاتى: طبّقه بـpsql لو الشاشة هتُستخدم هناك.

insert into public.app_pages(key, file, title, section, sort_order, is_active)
values ('customer_regions','customer_regions.html','تعيين مناطق العملاء','المبيعات والعملاء',213,true)
on conflict (key) do update
  set file=excluded.file, title=excluded.title, section=excluded.section,
      sort_order=excluded.sort_order, is_active=excluded.is_active;

-- الأدوار: الأدمن كل الفروع؛ مدير الفرع/الموظف/الكاشير فرعهم؛ الباقى محجوب.
insert into public.page_permissions(role, page, page_key, can_view, can_edit, all_branches, sort_order) values
  ('admin',     'customer_regions.html','customer_regions', true,  true,  true,  13),
  ('manager',   'customer_regions.html','customer_regions', true,  true,  false, 13),
  ('employee',  'customer_regions.html','customer_regions', true,  true,  false, 13),
  ('cashier',   'customer_regions.html','customer_regions', true,  true,  false, 13),
  ('accountant','customer_regions.html','customer_regions', false, false, false, 13),
  ('inventory', 'customer_regions.html','customer_regions', false, false, false, 13),
  ('pharmacist','customer_regions.html','customer_regions', false, false, false, 13),
  ('reviewer',  'customer_regions.html','customer_regions', false, false, false, 13),
  ('supervisor','customer_regions.html','customer_regions', false, false, false, 13)
on conflict (role, page) do update
  set page_key=excluded.page_key, can_view=excluded.can_view,
      can_edit=excluded.can_edit, all_branches=excluded.all_branches,
      sort_order=excluded.sort_order;
