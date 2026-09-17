-- ═══════════════════════════════════════════════════════════════════
-- صلاحيات التبويبات جوّه الشاشة (مش الشاشة كلها بس)
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-17)
--
-- • app_page_tabs: كتالوج تبويبات كل شاشة + selector الأزرار اللي بتفتحه
--   (الشاشة بتنادي Session.guardTabs('key') بس — مفيش خريطة في كل صفحة).
-- • tab_permissions: المنع بس. مفيش صف = مسموح. يعني أي تبويب جديد أو دور
--   جديد بياخد الشاشة كاملة زي قبل كده لحد ما الأدمن يقفل حاجة.
-- • الأدمن دايمًا شايف كل التبويبات.
-- • زي صلاحيات الصفحات: الإخفاء في الواجهة. البيانات نفسها محمية بحراسة
--   RPCs كل شاشة (لو موجودة)، مش بالجدول ده.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.app_page_tabs (
  page_key   text NOT NULL,
  tab_key    text NOT NULL,
  title      text NOT NULL,
  selector   text NOT NULL,           -- CSS للأزرار اللي بتفتح التبويب (تاب/درج/تاب فرعي)
  sort_order int  NOT NULL DEFAULT 0, -- الأول = التبويب الافتراضي للشاشة
  PRIMARY KEY (page_key, tab_key)
);

CREATE TABLE IF NOT EXISTS public.tab_permissions (
  role       text NOT NULL,
  page_key   text NOT NULL,
  tab_key    text NOT NULL,
  allowed    boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text,
  PRIMARY KEY (role, page_key, tab_key),
  FOREIGN KEY (page_key, tab_key) REFERENCES public.app_page_tabs (page_key, tab_key) ON DELETE CASCADE
);

ALTER TABLE public.app_page_tabs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tab_permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS app_page_tabs_read   ON public.app_page_tabs;
DROP POLICY IF EXISTS tab_permissions_read ON public.tab_permissions;
CREATE POLICY app_page_tabs_read   ON public.app_page_tabs   FOR SELECT TO authenticated USING (true);
CREATE POLICY tab_permissions_read ON public.tab_permissions FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.app_page_tabs, public.tab_permissions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.app_page_tabs, public.tab_permissions TO authenticated;

-- ── الكتالوج ────────────────────────────────────────────────────────
INSERT INTO public.app_page_tabs (page_key, tab_key, title, selector, sort_order) VALUES
 ('reports','drivers','تقارير الطيارين','#tabBtn-drivers',1),
 ('reports','orders','تقارير الطلبات','#tabBtn-orders',2),
 ('reports','incentives','حوافز الطيارين','#tabBtn-incentives',3),
 ('reports','jard','تقارير الجرد','#tabBtn-jard',4),
 ('reports','prep','تحضير الطلبات','#tabBtn-prep',5),
 ('reports','sa_overview','نظرة عامة المبيعات','#tabBtn-sa_overview',6),
 ('reports','sa_emp','أداء الموظفين','#tabBtn-sa_emp',7),
 ('reports','sa_price','مراجعة الأسعار','#tabBtn-sa_price',8),
 ('reports','sa_disc','فواتير الخصومات','#tabBtn-sa_disc',9),

 ('inventory','scan','جرد بالكود','#tt-scan, #di-scan',1),
 ('inventory','items','الأصناف','#tt-items, .drawer-item[onclick^="pickCategory"]',2),
 ('inventory','reports','التقارير','#tt-reports, #rst-full, #rst-stale, .drawer-item[onclick^="fromDrawer"]',3),

 ('medicine_orders','orders','الطلبيات','#tabbtn-orders',1),
 ('medicine_orders','rate','معدل الاستهلاك','#tabbtn-rate',2),
 ('medicine_orders','replace','الأكواد البديلة','#tabbtn-replace',3),
 ('medicine_orders','exceptional','الأصناف الاستثنائية','#tabbtn-exceptional',4),
 ('medicine_orders','tiers','شرائح كمية الطلب','#tabbtn-tiers',5),
 ('medicine_orders','archive','الأرشيف','#tabbtn-archive',6),
 ('medicine_orders','newitems','أصناف جديدة','#tabbtn-newitems',7),
 ('medicine_orders','settings','إعدادات المشتريات','#tabbtn-settings',8),

 ('inventory_management','prices','فرق الأسعار بين الفروع','.tab-btn[data-tab="prices"]',1),
 ('inventory_management','transfer','تحويل بين الفروع','.tab-btn[data-tab="transfer"]',2),
 ('inventory_management','missing','ناقص من فرع','.tab-btn[data-tab="missing"]',3),
 ('inventory_management','pricechanges','تغيّرات الأسعار','.tab-btn[data-tab="pricechanges"]',4),
 ('inventory_management','disbursement','أذون الصرف','.tab-btn[data-tab="disbursement"]',5),
 ('inventory_management','overstock','مخزون زائد','.tab-btn[data-tab="overstock"]',6),
 ('inventory_management','lookup','بحث في المخزون','.tab-btn[data-tab="lookup"]',7),

 ('shift_history','shifts','الإغلاقات','#tab-shifts',1),
 ('shift_history','transfers','التحويلات','#tab-transfers',2),
 ('shift_history','recon','المطابقة','#tab-recon',3),
 ('shift_history','balance','الرصيد الحالي','#tab-balance',4),

 ('customers','search','بحث العملاء','.tab-btn[data-tab="search"]',1),
 ('customers','employees','الموظفين','.tab-btn[data-tab="employees"]',2),
 ('customers','clients','العملاء','.tab-btn[data-tab="clients"]',3),

 ('supplier_balances','balances','أرصدة الفروع','button.tab[data-tab]:not([data-tab="mov"]):not([data-tab="ex"]):not([data-tab="set"])',1),
 ('supplier_balances','mov','مصروفات الموردين','button.tab[data-tab="mov"]',2),
 ('supplier_balances','ex','الاستثناءات','button.tab[data-tab="ex"]',3),
 ('supplier_balances','set','الإعدادات','button.tab[data-tab="set"]',4),

 ('tasks','schedule','الجدول','#tab-btn-schedule',1),
 ('tasks','all','كل المهام','#tab-btn-all',2),

 ('sales_contracts','invoices','الفواتير','#tab-btn-invoices',1),
 ('sales_contracts','returns','مرتجعات التعاقد','#tab-btn-returns',2),

 ('expenses','list','المصروفات','.exp-tab-btn[data-tab="list"]',1),
 ('expenses','rules','القواعد','.exp-tab-btn[data-tab="rules"]',2),

 ('claims','pending','جاهزة للمطالبة','.tab-btn[onclick*="''pending''"]',1),
 ('claims','claims','المطالبات المرسلة','.tab-btn[onclick*="''claims''"]',2)
ON CONFLICT (page_key, tab_key) DO UPDATE
  SET title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

-- ── القراءة: التبويبات الممنوعة على دور ────────────────────────────
CREATE OR REPLACE FUNCTION public.get_role_tabs(p_role text)
RETURNS TABLE (page_key text, tab_key text, title text, selector text, sort_order int, allowed boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
  SELECT t.page_key, t.tab_key, t.title, t.selector, t.sort_order,
         CASE WHEN lower(btrim(coalesce(p_role,''))) = 'admin' THEN true
              ELSE coalesce(p.allowed, true) END
    FROM app_page_tabs t
    LEFT JOIN tab_permissions p
      ON p.page_key = t.page_key AND p.tab_key = t.tab_key AND p.role = lower(btrim(coalesce(p_role,'')))
   ORDER BY t.page_key, t.sort_order;
$fn$;

-- ── الحفظ (الأدمن بس) ───────────────────────────────────────────────
-- p_updates: [{role, page_key, tab_key, allowed}]
CREATE OR REPLACE FUNCTION public.save_tab_permissions_bulk(p_updates jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_n int := 0; v_by text;
BEGIN
  PERFORM public.require_app_role(ARRAY['admin']);
  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb -> 'app_metadata' ->> 'full_name', 'admin');
  INSERT INTO tab_permissions (role, page_key, tab_key, allowed, updated_at, updated_by)
  SELECT lower(btrim(u ->> 'role')), u ->> 'page_key', u ->> 'tab_key', coalesce((u ->> 'allowed')::boolean, true), now(), v_by
    FROM jsonb_array_elements(p_updates) u
   WHERE coalesce(u ->> 'role','') <> '' AND lower(btrim(u ->> 'role')) <> 'admin'
     AND EXISTS (SELECT 1 FROM app_page_tabs t WHERE t.page_key = u ->> 'page_key' AND t.tab_key = u ->> 'tab_key')
  ON CONFLICT (role, page_key, tab_key) DO UPDATE
    SET allowed = excluded.allowed, updated_at = now(), updated_by = excluded.updated_by;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'saved', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.get_role_tabs(text), public.save_tab_permissions_bulk(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_role_tabs(text), public.save_tab_permissions_bulk(jsonb) TO authenticated, service_role;

COMMIT;
