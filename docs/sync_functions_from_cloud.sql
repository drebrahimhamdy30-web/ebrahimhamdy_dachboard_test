-- ═══════════════════════════════════════════════════════════════════
--  سحب تعريف الدوال المنحرفة من السحابة للسيرفر
-- ═══════════════════════════════════════════════════════════════════
--  المشكلة: 17 دالة على السيرفر جسمها أقدم من السحابة. اتعدّلت هناك
--  مباشرة وملفات الـmigration ماخدتش التعديل (أوضح مثال:
--  get_kpi_dashboard — migrate_25 اتكتب فيه **وصف** التعديل مش الكود،
--  فشاشة مؤشر الأداء طلعت فاضية في جزء خدمة العملاء).
--
--  الحل: نسحب التعريف الحالي من public.v_migration_ddl على السحابة
--  (view بيتحسب لحظيًا من الكتالوج) عبر postgres_fdw وننفّذه هنا.
--  مفيش نسخ يدوي = مفيش غلطة نسخ.
--
--  ═══ 🔒 6 دوال مستثناة عن عمد ═══
--    notify_fcm_on_assign · notify_on_driver_change · trg_delivery_perf
--    trg_fail_perf · trg_trip_return_perf · sweep_unrated_perf
--
--  دي **معدّلة على السيرفر عن قصد** عشان تنده دوال السيرفر بدل
--  السحابة. لو كتبنا نسخة السحابة فوقها، أول طلب تجريبي هيبعت إشعار
--  حقيقي لطيار شغّال دلوقتي، وتقييمات الأداء هتضرب Google Maps
--  بفلوس. تتعمل يوم التحويل مع فك العزل، مش قبله.
--
--  ═══ الحارس ═══
--  أي تعريف جاي من السحابة فيه رابط السحابة أو نداء HTTP بيتـ**رفض**
--  ويتسجّل للمراجعة اليدوية — حتى لو مش في قايمة المستثناة. الافتراض
--  إن القايمة ناقصة أأمن من الافتراض إنها كاملة.
--
--  التشغيل:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/sync_functions_from_cloud.sql
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

-- الـview مش متقاسم في cloudsrc أصلًا (استوردنا الجداول بس)
drop foreign table if exists cloudsrc.v_migration_ddl;
import foreign schema public limit to (v_migration_ddl) from server cloud into cloudsrc;

do $fn$
declare
  TARGETS constant text[] := array[
    'auto_dispatch_tick','bank_classify','bank_import_statement',
    'ci_freeze_reviewed_total','get_contract_returns','get_kpi_dashboard',
    'get_min_stock_alerts','manual_assign_order','merge_contract_invoices',
    'resolve_jard_audit','set_stock_limit','submit_jard_audit',
    'transfer_orders_to_driver','trg_server_event_time','trg_sla_rating',
    'unmerge_contract_invoice','update_last_activated'
  ];
  r record;
  n_ok int := 0; n_block int := 0; n_fail int := 0;
begin
  for r in
    select obj, ddl from cloudsrc.v_migration_ddl
    where kind = 'function' and obj = any (TARGETS)
    order by obj
  loop
    -- الحارس: نداء خارجي أو رابط السحابة = وقف
    if r.ddl ~* 'supabase\.co|rxtjoqulmgkkcohmgzgi|net\.http_post|http_post|pg_net' then
      raise notice '🔒 اتوقف: %  (فيه نداء خارجي — محتاج مراجعة يدوية)', r.obj;
      n_block := n_block + 1;
      continue;
    end if;

    begin
      execute r.ddl;
      raise notice '  ✓ %', r.obj;
      n_ok := n_ok + 1;
    exception when others then
      raise notice '  ✗ %  →  %', r.obj, left(sqlerrm, 130);
      n_fail := n_fail + 1;
    end;
  end loop;

  raise notice '═══ اتحدّثت: %  ·  اتوقفت للمراجعة: %  ·  فشلت: % ═══',
    n_ok, n_block, n_fail;
end $fn$;

-- ── التحقق: نعيد حساب البصمة ونشوف الفرق قلّ ───────────────────────
-- (شغّل schema_diff_funcbody_vs_prod.sql بعد كده — المفروض يفضل
--  6 دوال مختلفة بس، وهي الـ6 المستثناة عن عمد)
select count(*) as "دوال public"
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f';
