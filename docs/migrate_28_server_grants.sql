-- ═══════════════════════════════════════════════════════════════════
--  migrate_28 — صلاحيات الجداول الجديدة على السيرفر الذاتي
-- ═══════════════════════════════════════════════════════════════════
--  السحابة بتدّي الجرانت تلقائيًا لأي جدول جديد (default privileges)،
--  السيرفر الذاتي مش بالضرورة. والجرانت والـRLS فحصين **منفصلين** —
--  ممكن البوليسي تكون مفتوحة والجدول يرجّع 42501 permission denied.
--
--  القيم دي مأخوذة من البرودكشن حرفيًا (role_table_grants) 2026-09-17:
--    • anon مالوش أي صلاحية على الجداول دي — وده مقصود، الشاشات
--      بتقراها بحساب مسجّل دخول. ماتضيفش anon هنا.
--    • جداول السجلات والإعدادات: authenticated قراءة بس، والكتابة
--      بتتم عبر دوال SECURITY DEFINER.
--    • جداول الشاشات بتكتب فيها مباشرة: قراءة وكتابة.
--
--  GRANT بيضيف مابيسحبش، فآمن يتعاد تشغيله.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── قراءة بس (الكتابة عبر دوال) ─────────────────────────────────────
GRANT SELECT ON TABLE
  public.app_page_tabs,
  public.bank_settings,
  public.bank_transactions,
  public.contract_invoice_value_fixes,
  public.contract_merge_log,
  public.jard_checkins,
  public.tab_permissions
TO authenticated;

-- ── قراءة وكتابة (الشاشة بتكتب مباشرة) ──────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.integration_branch_stores,
  public.supplier_balance_notes,
  public.supplier_collection_returns,
  public.supplier_collections
TO authenticated;

-- ── service_role (الدوال والمزامنة) ─────────────────────────────────
GRANT ALL ON TABLE
  public.app_page_tabs,
  public.bank_settings,
  public.bank_transactions,
  public.contract_invoice_value_fixes,
  public.contract_merge_log,
  public.integration_branch_stores,
  public.jard_checkins,
  public.supplier_balance_notes,
  public.supplier_collection_returns,
  public.supplier_collections,
  public.tab_permissions
TO service_role;

-- ── التسلسلات (من غيرها INSERT بيفشل بـpermission denied for sequence) ──
DO $$
DECLARE s record;
BEGIN
  FOR s IN
    SELECT c.oid::regclass::text AS seq
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'a'
    JOIN pg_class t ON t.oid = d.refobjid
    WHERE n.nspname = 'public' AND c.relkind = 'S'
      AND t.relname IN ('integration_branch_stores','supplier_balance_notes',
                        'supplier_collection_returns','supplier_collections',
                        'bank_transactions','jard_checkins','contract_merge_log',
                        'contract_invoice_value_fixes','app_page_tabs','tab_permissions')
  LOOP
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO authenticated, service_role', s.seq);
  END LOOP;
END $$;

COMMIT;

-- الفحص: المفروض يطلع نفس اللي في البرودكشن
SELECT table_name AS "الجدول", grantee AS "الدور",
       string_agg(privilege_type, ',' ORDER BY privilege_type) AS "الصلاحيات"
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND grantee IN ('anon','authenticated')
  AND table_name IN ('app_page_tabs','bank_settings','bank_transactions',
                     'contract_invoice_value_fixes','contract_merge_log',
                     'integration_branch_stores','jard_checkins','supplier_balance_notes',
                     'supplier_collection_returns','supplier_collections','tab_permissions')
GROUP BY table_name, grantee
ORDER BY table_name, grantee;
