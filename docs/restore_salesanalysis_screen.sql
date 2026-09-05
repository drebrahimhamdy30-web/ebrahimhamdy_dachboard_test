-- ═══════════════════════════════════════════════════════════════════
-- رجوع شاشة «تحليل المبيعات» المستقلة  (لو احتاجناها تاني)
-- ═══════════════════════════════════════════════════════════════════
-- الشاشة اتشالت في 2026-09-05 بعد ما تبويباتها الأربعة اتنقلت جوّه
-- شاشة التقارير (delivery/pages/reports.html):
--     نظرة عامة · أداء الموظفين · مراجعة الأسعار · فواتير الخصومات
--
-- اللي اتشال:
--   1. الملف salesanalysis.html          → في git، رجّعه بـgit checkout
--   2. مرجعين في delivery/app.html       → في git برضه
--   3. صف app_pages + 9 صفوف page_permissions → الملف ده بيرجّعهم
--
-- ⚠️ رجوع الملف نفسه (من جذر الريبو):
--     git checkout <آخر-كوميت-قبل-الحذف> -- salesanalysis.html
--   ولو مش فاكر الكوميت:
--     git log --oneline --diff-filter=D -- salesanalysis.html
--
-- ⚠️ ملاحظة: الملف بيعتمد على 18 دالة في api.js (sbSales*/sbDelivery*/
--   sbMark*/sbBillItems). لو اتشالوا من api.js بعد كده، لازم يرجعوا معاه.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1) صف الكتالوج ──────────────────────────────────────────────
INSERT INTO public.app_pages (key, file, title, section, sort_order, badge, is_active)
VALUES ('salesanalysis', 'salesanalysis.html', 'تحليل المبيعات', 'نظرة عامة', 103, NULL, true)
ON CONFLICT (key) DO UPDATE
   SET file = EXCLUDED.file, title = EXCLUDED.title, section = EXCLUDED.section,
       sort_order = EXCLUDED.sort_order, is_active = true;

-- ── 2) صلاحيات الأدوار (نفس القيم وقت الحذف بالظبط) ─────────────
--    admin: عرض+تعديل · manager: عرض فقط · الباقي: مقفول
INSERT INTO public.page_permissions (role, page, page_key, can_view, can_edit, sort_order)
VALUES
  ('admin',      'salesanalysis.html', 'salesanalysis', true,  true,  90),
  ('manager',    'salesanalysis.html', 'salesanalysis', true,  false, 90),
  ('supervisor', 'salesanalysis.html', 'salesanalysis', false, false, 90),
  ('pharmacist', 'salesanalysis.html', 'salesanalysis', false, false, 90),
  ('cashier',    'salesanalysis.html', 'salesanalysis', false, false, 90),
  ('accountant', 'salesanalysis.html', 'salesanalysis', false, false, 90),
  ('reviewer',   'salesanalysis.html', 'salesanalysis', false, false, NULL),
  ('inventory',  'salesanalysis.html', 'salesanalysis', false, false, 90),
  ('employee',   'salesanalysis.html', 'salesanalysis', false, false, 90)
ON CONFLICT DO NOTHING;

COMMIT;

-- ── فحص بعد التشغيل ─────────────────────────────────────────────
-- SELECT key, title, is_active FROM public.app_pages WHERE key = 'salesanalysis';
-- SELECT role, can_view, can_edit FROM public.page_permissions
--  WHERE page_key = 'salesanalysis' ORDER BY role;
