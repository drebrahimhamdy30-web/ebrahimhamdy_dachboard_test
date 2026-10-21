/* ============================================================
   تسجيل شاشة «مطابقة خزنة visa» في القائمة والصلاحيات
   ------------------------------------------------------------
   ⚠️ أي شاشة جديدة لازم صف في app_pages + صفوف في page_permissions،
   وإلا مش هتظهر في القائمة ولا هيقدر حد يفتحها.

   الصلاحية للأدوار اللي بتراجع الخزنة بس (admin · manager · accountant)
   — نفس حراسة الدوال في migrate_147، لأن الشاشة بتكشف أرصدة الخزائن
   والمحافظ لكل الفروع.
   ============================================================ */
insert into app_pages (key, file, title, section, sort_order, is_active)
values ('visa_recon', 'visa_recon.html', 'مطابقة خزنة visa', 'الحسابات والخزينة', 636, true)
on conflict (key) do update
  set file = excluded.file, title = excluded.title,
      section = excluded.section, sort_order = excluded.sort_order, is_active = true;

insert into page_permissions (page_key, role)
select 'visa_recon', r from unnest(array['admin','manager','accountant']) r
on conflict do nothing;
