-- ═══════════════════════════════════════════════════════════════════
--  migrate_31 — الباقي من فرق الصلاحيات (٣ حاجات فاتت في migrate_30)
-- ═══════════════════════════════════════════════════════════════════
--  بعد migrate_30 نزل الفرق من 196 لـ11+11. الباقي اتفسّر كده:
--
--  1) **الـviews** — حلقة السحب في migrate_30 كانت على الجداول بس
--     (relkind='r')، فالـviews فضلت بصلاحيات واسعة:
--        v_trip_perf · v_store_item_prices · v_supplier_movements
--        v_branch_value_audit · v_stock_units_full
--     السحابة بتدي authenticated قراءة بس، والسيرفر كان مديله
--     DELETE/INSERT/TRUNCATE كمان.
--
--  2) **service_role على الدوال** — أمر fn_acl الجاي من السحابة بيسحب
--     من `public, anon, authenticated` بس. فالزيادة على service_role
--     مابتتشالش. 10 دوال منها حساسة: save_role_permissions ·
--     change_branch_user_password · transfer_orders_to_driver ·
--     manual_assign_order · merge/unmerge_contract_invoice.
--     الخطر أقل من authenticated (service_role مفتاح سرّي مش بيتوزّع)
--     بس المبدأ واحد: السيرفر يطابق البرودكشن مش يبقى أوسع منه.
--
--  3) **دالة ناقصة**: search_stock_items موجودة على السحابة ومش هنا.
--
--  الباقي المعروف والمقصود: جدولين النسخ المؤقتة
--  (pos_shifts_dupe_backup_20260905 · wallet_done_backfill_20260910)
--  مش منقولين، فصلاحياتهم مش موجودة — وده صح.
--
--  آمن يتعاد تشغيله.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'cloudsrc' and c.relname = 'v_migration_ddl') then
    execute 'import foreign schema public limit to (v_migration_ddl) from server cloud into cloudsrc';
  end if;
end $$;

BEGIN;

-- ── 1) الدالة الناقصة ───────────────────────────────────────────────
do $f$
declare r record; n int := 0;
begin
  for r in
    select obj, ddl from cloudsrc.v_migration_ddl
    where kind = 'function' and obj = 'search_stock_items'
  loop
    -- نفس حارس sync_functions_from_cloud: مفيش نداء خارجي يعدّي
    if r.ddl ~* 'supabase\.co|rxtjoqulmgkkcohmgzgi|net\.http_post|pg_net' then
      raise notice '🔒 اتوقفت: % (فيها نداء خارجي)', r.obj;
    else
      execute r.ddl;
      n := n + 1;
    end if;
  end loop;
  raise notice '═══ دوال ناقصة اتضافت: % ═══', n;
end $f$;

-- ── 2) الـviews: سحب ثم إعطاء بنسخة السحابة ────────────────────────
do $v$
declare r record; n_rev int := 0; n_grant int := 0;
begin
  for r in
    select c.relname::text as v
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and c.relname !~ '^v_migration_'
    order by 1
  loop
    execute format('revoke all on table public.%I from anon, authenticated, service_role', r.v);
    n_rev := n_rev + 1;
  end loop;

  -- الجرانت بتاع السحابة بيشمل الـviews (information_schema بيعتبرها جداول)
  for r in select ddl from cloudsrc.v_migration_ddl where kind = 'grant'
  loop
    begin
      execute r.ddl; n_grant := n_grant + 1;
    exception when undefined_table then null;
    end;
  end loop;

  raise notice '═══ views اتسحبت: %  ·  صلاحيات اتعطت: % ═══', n_rev, n_grant;
end $v$;

-- ── 3) الدوال: نسحب من service_role كمان قبل الإعطاء ───────────────
-- أمر السحابة بيسحب من public, anon, authenticated — بنزوّد
-- service_role على السحب بس، والإعطاء يفضل زي السحابة بالظبط.
do $a$
declare r record; n int := 0; v_ddl text;
begin
  for r in select obj, ddl from cloudsrc.v_migration_ddl where kind = 'fn_acl'
  loop
    v_ddl := replace(r.ddl,
      'from public, anon, authenticated;',
      'from public, anon, authenticated, service_role;');
    begin
      execute v_ddl; n := n + 1;
    exception when undefined_function or undefined_table then null;
    end;
  end loop;
  raise notice '═══ صلاحيات تنفيذ الدوال اتظبطت: % ═══', n;
end $a$;

COMMIT;

-- ── التحقق ─────────────────────────────────────────────────────────
with n_cloud as (
  select kind, obj, regexp_replace(regexp_replace(replace(ddl,'public.',''),'\s+',' ','g'),';\s*$','') d
  from cloudsrc.v_migration_ddl where kind in ('grant','fn_acl','function')
    and obj not in ('pos_shifts_dupe_backup_20260905:service_role',
                    'wallet_done_backfill_20260910:service_role')
    and split_part(obj,':',1) not in ('pos_shifts_dupe_backup_20260905',
                                      'wallet_done_backfill_20260910')
), n_srv as (
  select kind, obj, regexp_replace(regexp_replace(replace(ddl,'public.',''),'\s+',' ','g'),';\s*$','') d
  from public.v_migration_ddl where kind in ('grant','fn_acl','function')
)
select c.kind as "النوع", count(*) as "لسه منحرف"
from n_cloud c
where not exists (select 1 from n_srv s where s.kind = c.kind and s.d = c.d)
group by 1 order by 2 desc;
