-- ═══════════════════════════════════════════════════════════════════
-- تفعيل RLS على 8 جداول كانت مكشوفة — طبقة حماية تانية
-- ═══════════════════════════════════════════════════════════════════
-- الفحص اللي اتعمل قبل الملف ده (على البرودكشن 2026-09-13):
--
--   1) الصلاحيات الفعلية: **anon مالوش أي صلاحية على الـ8**. شغل إغلاق
--      anon اللي اتعمل قبل كده غطّاهم. يعني تحذير «anyone with the anon
--      key can read or modify every row» مبالغ — الجرانت مقفول أصلًا.
--      الاستثناء الوحيد: branch_scope_values عليه SELECT لـauthenticated.
--
--   2) مين بيقراهم فعلًا: 9 دوال كلها **SECURITY DEFINER** —
--      audit_branch_values · propagate_branch_rename · get_shortages ·
--      get_stock_limits · get_stock_summary · item_balance · item_lookup ·
--      rebind_v_stock_units_full · refresh_stock_flat
--      وview واحدة v_stock_units_full بـsecurity_invoker=false.
--      الاتنين بيشتغلوا بصلاحية المالك و**بيتخطّوا RLS**، فتفعيله
--      مش هيكسر ولا واحد فيهم.
--
--   3) مفيش أي كود في الريبوهين بيقرا الجداول دي مباشرة — كله عن طريق
--      الـRPCs اللي فوق.
--
--   4) n8n بيتصل مباشرة بكلمة سر القاعدة (دور superuser) — بيتخطّى RLS.
--
-- الخلاصة: التفعيل **آمن** ومكسبه إن أي جرانت يتضاف بالغلط بعدين
-- مايفتحش الجداول على مصراعيها.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── 7 جداول: RLS من غير أي سياسة ──────────────────────────────────
-- مفيش دور تطبيقي بيوصلهم مباشرة، والدوال SECURITY DEFINER بتعدّي.
ALTER TABLE public.branch_rename_log                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_shifts_dupe_backup_20260905  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_done_backfill_20260910    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_bishr                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_san                        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_mamora                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_bishr_staging              ENABLE ROW LEVEL SECURITY;

-- ── branch_scope_values: عليه SELECT لـauthenticated ──────────────
-- محتواه صفّين مالهمش أي حساسية («عام» و«كل الفروع» + ملاحظة).
-- مفيش كود بيقراه، بس بنسيب القراءة شغّالة عشان التفعيل ما يكسرش
-- مستهلك مش شايفينه. الكتابة مقفولة مرتين: مفيش جرانت ومفيش سياسة.
ALTER TABLE public.branch_scope_values ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS branch_scope_values_read ON public.branch_scope_values;
CREATE POLICY branch_scope_values_read
  ON public.branch_scope_values FOR SELECT TO authenticated USING (true);

COMMIT;

-- ── فحص بعد التشغيل ────────────────────────────────────────────────
-- select relname, relrowsecurity from pg_class
--  where relname in ('branch_rename_log','branch_scope_values','pos_shifts_dupe_backup_20260905',
--                    'wallet_done_backfill_20260910','stock_bishr','stock_san','stock_mamora','stock_bishr_staging');
--
-- وبعدها جرّب الشاشات اللي بتستهلك الدوال دي:
--   • «طلبيات الأدوية» (get_stock_summary / get_shortages)
--   • «النواقص» و«فحص الأسعار» (item_lookup / item_balance)
--   • البحث السريع في البار (quick_search_stock)
--
-- ⚠️ ملحوظة مش داخلة في الملف ده عن قصد: pos_shifts_dupe_backup_20260905
--    و wallet_done_backfill_20260910 نسخ احتياطية لعمليات خلصت. لو
--    مش محتاجهم، حذفهم أنضف من تأمينهم — بس ده قرار المالك.
