-- ═══════════════════════════════════════════════════════════════════
--  فرق الفهارس والقيود: السيرفر الذاتي مقابل البرودكشن
-- ═══════════════════════════════════════════════════════════════════
--  الجولة الأولى (schema_diff_vs_prod.sql) قارنت الجداول والأعمدة
--  والدوال والسياسات. دي بتقارن **الفهارس والقيود** — ودي مش تفصيلة:
--  قيد UNIQUE ناقص معناه إن السيرفر يقبل بيانات مكررة البرودكشن يرفضها.
--
--  بصمة لكل جدول = md5(أسماء قيوده + أنواعها + أسماء فهارسه).
--  بيطلّع الجداول المختلفة بس، وبعدها تفاصيل الفرق للجداول دي.
--
--  لقطة البرودكشن: 2026-09-17 من rxtjoqulmgkkcohmgzgi
--
--    cd /root/supabase-project
--    CID=$(docker compose ps -q db)
--    docker exec -i $CID psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/schema_diff_idx_vs_prod.sql
-- ═══════════════════════════════════════════════════════════════════

create temp table prod_fp as
select split_part(l,'|',1) as tbl, split_part(l,'|',2) as fp
from unnest(string_to_array($FP$
app_control|c5206417
app_page_tabs|7cb8da28
app_pages|1693f45d
archived_items|b52467f1
archived_items_backup_20260824|01abfc75
backup_runs|103e47af
bank_settings|98ec75ee
bank_transactions|3c68b03e
branch_map|75b02eff
branch_rename_log|fdb42aae
branch_scope_values|6f5b16a8
branch_sessions|27dc8089
branch_stores|bdad8d6a
branch_users|33dd6e40
branches|4914cbf3
code_match_suggestions|6e2977f1
code_replace|39448ef1
code_sugg_queue|b886aada
consumption_exceptional|00cda3cb
consumption_flat|dc1d0d1f
contract_invoice_value_fixes|f7d52722
contract_invoices|afd79d2f
contract_merge_log|70d8b06d
contract_return_matches|bbc81b50
contracts|91dc8374
cosmo_states|3daf8d6e
demand_tiers|f7def0c6
dispatch_settings|1639e197
driver_app_version|617fc2e5
driver_attendance|818b1714
driver_breaks|acc01f56
driver_debug|2e573f24
driver_events|3a70d7f8
driver_fcm_tokens|e75395b4
driver_locations|d1c0f48d
driver_push_subscriptions|473e265c
driver_queue_rank|832ee275
drivers|dde50c9f
eplus_pos|474205a8
eplus_sales|3e30e60d
eplus_supplies|ad2efa68
erp_expense_hide_rules|232bd96e
erp_expenses|d6e70a7c
ex_archived_items|21d60fbf
gift_campaigns|df43fb7e
gift_list|a28dd905
imported_sales|8bfb7034
instructions|49379101
integration_branch_stores|7cc3b95e
integration_data|5be2b00b
integration_endpoints|94789712
jard_audit_log|4b4a62a4
jard_category_flags|209cf0a4
jard_checkins|564115bc
jard_erp|b843c68f
jard_excluded_codes|eab9b8c8
jard_fastmove_codes|a543742e
jard_settings|238a19c5
known_item_codes|1c5900d8
material_prices|abe9c49c
missing_items|f0e13894
monthly_sales|9b5d6e31
notification|52ae546a
offers|06c0f1be
order_logs|6c0dd5e0
order_selections|d37b9642
order_store_override|102782f1
order_transfer_pending|a1f28339
orders|1d60337d
org_settings|61e3d8a1
overstock_exclusions|4bdce3df
page_permissions|4c4a6f72
password_resets|34b193e6
paymob_transactions|1f57f48c
pos_branch_opening|0a0a8949
pos_manual_transfers|8146202a
pos_methods|cea34d8b
pos_shift_lines|3569f72e
pos_shifts|45db8d3a
pos_shifts_dupe_backup_20260905|01abfc75
pos_transactions|dfb6fc40
pos_wallet_transfers|9eac2ae8
price_changes|6aeabc4f
problem_occurrences|ef5dbe3f
problem_responsible_roles|d656d3f8
problems|b3c7594b
purchase_orders_flat|35ce9b5b
purchase_settings|a1b18220
region_names|b094fe5f
regions|ce3646a4
returns_log|5efb2fa2
role_permissions|17d6ebb3
route_regions|bbc6c78c
routes|2441fd5a
sales_analysis_access|c3ac4a83
sales_discount_reviews|9a30c859
sales_items|5f270235
sales_price_review_exclusions|c6e77e46
sales_returns|3ebbe2b0
stock_bishr|850a8df9
stock_flat|a5273f81
stock_flat_meta|ced75e6b
stock_limit|d9707155
stock_mamora|66ea1362
stock_san|0e522a48
store_item_prices|d7075ce8
store_sheet_mappings|204250b9
stores|b1b331b6
supplier_balance_exclusions|28a4554b
supplier_balance_notes|d7dea4db
supplier_balance_runs|ae17154f
supplier_balance_settings|c9bc7bba
supplier_balance_snapshots|954f7758
supplier_collection_returns|95a72437
supplier_collections|8a21508d
supplier_movement_reviews|8b8c06a5
tab_permissions|9dfdfc92
task|3541cef9
task_assignee|5b8a680f
task_done|e299b459
tasks|3ed8808d
trip_logs|4babbf5e
trip_orders|e57d73aa
trip_review_flags|ad493e8e
trips|67ced7d1
wallet|a2635521
wallet_done_backfill_20260910|30b43cad
wallet_sms|00f963f6
$FP$, E'\n')) l where l <> '';

create temp view srv_fp as
select c.relname::text as tbl,
       left(md5(
         coalesce((select string_agg(con.conname||':'||con.contype::text, ',' order by con.conname)
                   from pg_constraint con where con.conrelid = c.oid), '') || '#' ||
         coalesce((select string_agg(i.indexname, ',' order by i.indexname)
                   from pg_indexes i where i.schemaname='public' and i.tablename = c.relname), '')
       ), 8) as fp
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r';

\echo '════ جداول فهارسها/قيودها مختلفة ════'
select p.tbl as "الجدول", p.fp as "البرودكشن", s.fp as "السيرفر"
from prod_fp p join srv_fp s using (tbl)
where p.fp <> s.fp
order by p.tbl;

\echo '════ قيود UNIQUE / PRIMARY KEY على السيرفر (للجداول المختلفة) ════'
-- ⚠️ دي أهم حتة: قيد فريد ناقص = السيرفر يقبل تكرار البرودكشن يرفضه
select c.relname as "الجدول", con.conname as "القيد",
       case con.contype when 'p' then 'مفتاح أساسي' when 'u' then 'فريد'
                        when 'f' then 'مفتاح خارجي' else con.contype::text end as "النوع"
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and con.contype in ('p','u','f')
  and c.relname in (select p.tbl from prod_fp p join srv_fp s using (tbl) where p.fp <> s.fp)
order by c.relname, con.contype, con.conname;

\echo '════ فهارس السيرفر (للجداول المختلفة) ════'
select tablename as "الجدول", indexname as "الفهرس"
from pg_indexes
where schemaname = 'public'
  and tablename in (select p.tbl from prod_fp p join srv_fp s using (tbl) where p.fp <> s.fp)
order by tablename, indexname;
