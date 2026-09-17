-- ═══════════════════════════════════════════════════════════════════
--  فرق السكيما: السيرفر الذاتي مقابل البرودكشن (السحابة)
-- ═══════════════════════════════════════════════════════════════════
--  لقطة البرودكشن مأخوذة 2026-09-17 من rxtjoqulmgkkcohmgzgi.
--  بيقرا بس. بيطلّع **الفرق فقط** — لو مفيش نتايج يبقى مطابق.
--
--  على السيرفر:
--    cd /root/supabase-project
--    CID=$(docker compose ps -q db)
--    docker exec -i $CID psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/schema_diff_vs_prod.sql
--
--  الأعمدة: الجداول ببصمة md5 لأسماء أعمدتها — لو الجدول موجود في
--  الاتنين والبصمة مختلفة يبقى فيه عمود ناقص أو زايد.
-- ═══════════════════════════════════════════════════════════════════

create temp table prod_obj as
select split_part(l,'|',1) as kind, split_part(l,'|',2) as name, split_part(l,'|',3) as fp
from unnest(string_to_array($DUMP$
table|app_control|77300d41
table|app_page_tabs|5239ddf6
table|app_pages|7e0feb11
table|archived_items|246e9c27
table|archived_items_backup_20260824|246e9c27
table|backup_runs|a2542fdc
table|bank_settings|251ffd51
table|bank_transactions|e085b3e5
table|branch_map|e7564d37
table|branch_rename_log|af143412
table|branch_scope_values|7bfd7444
table|branch_sessions|0b43ff3d
table|branch_stores|e10a73e0
table|branch_users|1a3491b2
table|branches|1e1b9422
table|code_match_suggestions|4a900e9f
table|code_replace|426b3fc1
table|code_sugg_queue|9d0307ba
table|consumption_exceptional|fe64998d
table|consumption_flat|4299c58d
table|contract_invoice_value_fixes|0b905d2e
table|contract_invoices|d1c016c5
table|contract_merge_log|27a5d2cd
table|contract_return_matches|98d7ac79
table|contracts|bc1d2c4f
table|cosmo_states|63dd5792
table|demand_tiers|197f664e
table|dispatch_settings|95aeba4e
table|driver_app_version|23cd7233
table|driver_attendance|4d954a47
table|driver_breaks|2b1ba6a2
table|driver_debug|d2740a93
table|driver_events|69e381a0
table|driver_fcm_tokens|8d060305
table|driver_locations|67450cda
table|driver_push_subscriptions|02373fae
table|driver_queue_rank|13b01d8f
table|drivers|06141c9c
table|eplus_pos|4f73e52f
table|eplus_sales|4293ac4d
table|eplus_supplies|0c6f3dbc
table|erp_expense_hide_rules|d7a3fa45
table|erp_expenses|61712111
table|ex_archived_items|ae552993
table|gift_campaigns|0036992a
table|gift_list|eded65d1
table|imported_sales|00c84c3f
table|instructions|90dd87ab
table|integration_branch_stores|b79d6d0d
table|integration_data|a968efdd
table|integration_endpoints|f130aacb
table|jard_audit_log|0a570d8c
table|jard_category_flags|26725d4d
table|jard_checkins|a9ed790c
table|jard_erp|75ab6622
table|jard_excluded_codes|dc507e56
table|jard_fastmove_codes|83fbe891
table|jard_settings|b26ce266
table|known_item_codes|ec7de550
table|material_prices|39c9b91c
table|missing_items|07dd1479
table|monthly_sales|02953416
table|notification|04a44c1f
table|offers|e62aefb6
table|order_logs|4131fc6b
table|order_selections|469460bc
table|order_store_override|bf465adc
table|order_transfer_pending|e54e9b48
table|orders|1c64e6a6
table|org_settings|cabeb092
table|overstock_exclusions|08fc827f
table|page_permissions|5622cf0b
table|password_resets|cbc6d5a0
table|paymob_transactions|3fd3492b
table|pos_branch_opening|78d8196d
table|pos_manual_transfers|35d44325
table|pos_methods|94da895f
table|pos_shift_lines|3efe7122
table|pos_shifts|9c554b10
table|pos_shifts_dupe_backup_20260905|9c554b10
table|pos_transactions|02b2db8d
table|pos_wallet_transfers|e99c2aa6
table|price_changes|efe87766
table|problem_occurrences|1046074a
table|problem_responsible_roles|62e878f3
table|problems|977b37c6
table|purchase_orders_flat|28f968c4
table|purchase_settings|880f44f7
table|region_names|62e878f3
table|regions|dc4aeb31
table|returns_log|3bd03ff8
table|role_permissions|e88989cd
table|route_regions|5c20c30b
table|routes|51f4d16b
table|sales_analysis_access|6e29d848
table|sales_discount_reviews|873156d6
table|sales_items|de8392e0
table|sales_price_review_exclusions|52db70cc
table|sales_returns|4bff6761
table|stock_bishr|f15e9f6a
table|stock_flat|69d9042e
table|stock_flat_meta|5d536f2d
table|stock_limit|f5ad09bb
table|stock_mamora|f15e9f6a
table|stock_san|f15e9f6a
table|store_item_prices|7a675085
table|store_sheet_mappings|f7a26dbe
table|stores|0900a389
table|supplier_balance_exclusions|ebb19211
table|supplier_balance_notes|8f7d2d4d
table|supplier_balance_runs|5fe1ccd9
table|supplier_balance_settings|427497f6
table|supplier_balance_snapshots|5a7cce05
table|supplier_collection_returns|06f43ec1
table|supplier_collections|607b2de0
table|supplier_movement_reviews|b0113f4f
table|tab_permissions|d2130767
table|task|1cd8c9b4
table|task_assignee|393cccfe
table|task_done|59a57475
table|tasks|cdd855ec
table|trip_logs|516446ae
table|trip_orders|cc7b386d
table|trip_review_flags|4b9b9529
table|trips|f2df2c21
table|wallet|fadb4ece
table|wallet_done_backfill_20260910|172542c3
table|wallet_sms|e40a490b
view|v_branch_value_audit|
view|v_migration_ddl|
view|v_migration_post|
view|v_stock_units_full|
view|v_store_item_prices|
view|v_supplier_movements|
view|v_trip_perf|
trigger|branch_users.trg_sync_branch_user_to_auth|
trigger|branches.trg_propagate_branch_rename|
trigger|contract_invoices.trg_ci_freeze_reviewed_total|
trigger|contracts.trg_contracts_touch|
trigger|driver_attendance.ranks_on_attendance|
trigger|driver_attendance.trg_prevent_duplicate_online|
trigger|driver_attendance.trg_stamp_attendance_branch|
trigger|driver_attendance.trg_sync_driver_is_online|
trigger|erp_expense_hide_rules.trg_erp_expense_hide_rules_updated_at|
trigger|erp_expenses.trg_erp_expenses_updated_at|
trigger|material_prices.trg_material_prices_touch|
trigger|missing_items.trg_missing_touch|
trigger|notification.trg_notification_updated_at|
trigger|offers.trg_offers_touch|
trigger|orders.order_gift|
trigger|orders.order_gift_release|
trigger|orders.order_late_deliver|
trigger|orders.order_total_recompute|
trigger|orders.orders_hold_failed|
trigger|orders.orders_unlink_on_release|
trigger|orders.set_dispatch_type_trg|
trigger|orders.trg_driver_order_event|
trigger|orders.trg_fail_perf|
trigger|orders.trg_last_activated|
trigger|orders.trg_notify_fcm_on_assign|
trigger|orders.trg_notify_on_driver_change|
trigger|orders.trg_prevent_assign_busy|
trigger|orders.trg_protect_locked_region|
trigger|orders.trg_server_event_time|
trigger|orders.trg_sla_rating|
trigger|page_permissions.trg_sync_page_permission_key|
trigger|returns_log.trg_return_value|
trigger|sales_items.trg_enrich_sale|
trigger|stock_limit.trg_stock_limit_touch|
trigger|supplier_collection_returns.trg_sync_collection_returns|
trigger|task.trg_task_require_item_name|
trigger|task.trg_task_touch|
trigger|task.trg_task_updated_at|
trigger|trip_orders.trg_no_dup_trip_order|
trigger|trip_orders.triporders_recompute|
trigger|trips.enforce_trip_complete|
trigger|trips.ranks_on_trip_insert|
trigger|trips.ranks_on_trip_status|
trigger|trips.trip_complete_cascade|
trigger|trips.trip_completed_freeze|
trigger|trips.trip_return_perf_trg|
trigger|trips.trips_driver_last_completed|
trigger|trips.trips_stamp_completed|
$DUMP$, E'\n')) l where l <> '';

-- الدوال والسياسات (لقطة البرودكشن) — أسماء بس، من غير أي بيانات
insert into prod_obj
select split_part(l,'|',1), split_part(l,'|',2), ''
from unnest(string_to_array($D2$
func|add_recon_txn/6
func|add_review_flag/8
func|admin_delete_branch_user/1
func|admin_toggle_branch_user/2
func|admin_upsert_branch_user/9
func|apply_sales_returns/0
func|ar_norm/1
func|audit_branch_values/0
func|auto_dispatch_tick/1
func|bank_actor/0
func|bank_add_manual/3
func|bank_can_use/0
func|bank_classify/3
func|bank_import_statement/3
func|bank_post/1
func|bank_set_opening/1
func|bank_set_source/2
func|best_store_for/2
func|branch_id/1
func|branch_name/1
func|branch_store_name/1
func|change_branch_user_password/3
func|change_driver_branch/3
func|check_trip_complete/0
func|ci_freeze_reviewed_total/0
func|cleanup_empty_trips/0
func|cleanup_old_logs/0
func|close_stale_open_sessions/0
func|compute_code_suggestions_batch/1
func|create_password_reset/1
func|delete_current_wallet_transfer/1
func|delete_month_sales/1
func|delivery_active_days/3
func|delivery_by_hour/3
func|difficult_driver_load/1
func|enrich_sale_row/0
func|ensure_integration_table/4
func|get_all_branch_users/0
func|get_branch_rep_users/0
func|get_closure_machine_recon/1
func|get_closure_machine_txns/2
func|get_completed_orders_for_bills/2
func|get_consumption_detail/1
func|get_consumption_rates/0
func|get_contract_returns/1
func|get_cs_orders/2
func|get_customer_names/1
func|get_driver_emails/0
func|get_driver_hard_trips_today/2
func|get_driver_month_stats/1
func|get_driver_rank/2
func|get_hard_load/1
func|get_hard_trips_month/1
func|get_hard_trips_today/1
func|get_jard_daily_stats/3
func|get_jard_efficiency/3
func|get_jard_full_report/4
func|get_kpi_dashboard/2
func|get_min_stock_alerts/0
func|get_new_items/0
func|get_open_review_flags/1
func|get_pos_balances_at/2
func|get_prep_report/3
func|get_prev_trip_orders/2
func|get_price_changes/0
func|get_purchase_companies/0
func|get_purchase_orders/0
func|get_role_pages/1
func|get_role_tabs/1
func|get_sales_summary/0
func|get_shortages/1
func|get_stock_limits/1
func|get_stock_summary/0
func|get_trip_counts/1
func|get_trip_review_flags/1
func|get_unclosed_orders/1
func|get_user_branch_map/0
func|get_user_name_map/0
func|item_balance/2
func|item_lookup/2
func|jard_checkin/1
func|jard_counted/3
func|jard_uncounted/3
func|jwt_all_branches/0
func|jwt_app_role/0
func|jwt_branch/0
func|jwt_branch_id/0
func|jwt_driver_id/0
func|jwt_user_id/0
func|list_public_tables/0
func|list_sales_months/0
func|lookup_customer_name/1
func|manager_toggle_driver/2
func|manager_upsert_driver/15
func|manual_assign_order/3
func|mark_item_coded/2
func|match_contract_return/5
func|merge_contract_invoices/3
func|move_recon_txn/4
func|notify_driver_order_event/0
func|notify_fcm_on_assign/0
func|notify_on_driver_change/0
func|num_tokens/1
func|order_route_tokens/2
func|pharma_prices_finalize/1
func|pharma_prices_upsert/1
func|prep_return_to_prep/2
func|prevent_assign_to_busy_driver/0
func|prevent_duplicate_online/0
func|prevent_duplicate_trip_order/0
func|propagate_branch_rename/0
func|protect_locked_region/0
func|quick_search_stock/2
func|rebind_v_stock_units_full/0
func|recompute_trip_total/1
func|recover_stuck_orders/0
func|refresh_consumption_rates/0
func|refresh_driver_ranks/1
func|refresh_purchase_orders/0
func|refresh_stock_flat/0
func|report_conflicting_codes/0
func|report_delivered_trip_completed/0
func|report_driver_location/4
func|report_shared_codes/0
func|req_qty/4
func|require_app_role/1
func|reset_password_with_code/3
func|reset_password_with_token/2
func|resolve_jard_audit/3
func|resolve_login_email/1
func|restore_table_from_json/3
func|review_price_change/2
func|sales_active_days/3
func|sales_by_day/3
func|sales_by_employee/3
func|sales_by_hour/3
func|sales_detail/7
func|sales_discount_bills/3
func|sales_discount_stats/3
func|sales_overview/3
func|sales_price_review/3
func|sales_summary/3
func|sales_top_items/4
func|save_page_permission/4
func|save_page_permissions_bulk/1
func|save_push_subscription/4
func|save_role_permissions/2
func|save_tab_permissions_bulk/1
func|set_driver_avatar/2
func|set_erp_expense_hide_rules_updated_at/0
func|set_erp_expenses_updated_at/0
func|set_notification_updated_at/0
func|set_order_region/2
func|set_return_value/0
func|set_stock_limit/5
func|set_task_updated_at/0
func|sort_letters/1
func|stamp_attendance_branch/0
func|store_delete/1
func|store_rename/2
func|submit_jard_audit/1
func|suggest_codes_for_names/1
func|suggest_contract_invoices/6
func|suggest_purchase_sources/1
func|suggest_stock_codes/2
func|sweep_unrated_perf/0
func|sync_branch_user_to_auth/0
func|sync_collection_returns_total/0
func|sync_driver_is_online/0
func|sync_page_permission_key/0
func|task_require_item_name/0
func|topup_code_suggestions/0
func|touch_updated_at/0
func|transfer_orders_to_driver/4
func|trg_delivery_perf/0
func|trg_fail_perf/0
func|trg_order_gift/0
func|trg_order_gift_release/0
func|trg_order_hold_failed/0
func|trg_order_late_deliver/0
func|trg_order_total_recompute/0
func|trg_order_unlink_on_release/0
func|trg_refresh_ranks/0
func|trg_server_event_time/0
func|trg_set_dispatch_type/0
func|trg_sla_rating/0
func|trg_trip_complete_cascade/0
func|trg_trip_completed_freeze/0
func|trg_trip_driver_last_completed/0
func|trg_trip_return_perf/0
func|trg_trip_stamp_completed/0
func|trg_triporders_recompute/0
func|unmatch_contract_return/2
func|unmerge_contract_invoice/2
func|update_last_activated/0
func|update_txn_time/3
func|upload_month_sales/2
func|upload_store_sheet/2
func|vault_secret/1
func|verify_branch_login/2
func|verify_branch_token/1
func|web_driver_fail_order/8
policy|app_control.app_control_read
policy|app_page_tabs.app_page_tabs_read
policy|app_pages.app_pages_read
policy|archived_items.p_all
policy|bank_settings.bank_set_read
policy|bank_transactions.bank_tx_read
policy|branch_map.branch_map_read
policy|branch_stores.branch_stores_delete
policy|branch_stores.branch_stores_insert
policy|branch_stores.branch_stores_read
policy|branches.allow_all_branches
policy|branches.allow_read
policy|code_match_suggestions.p_all
policy|code_replace.p_all
policy|consumption_exceptional.p_all
policy|consumption_flat.p_all
policy|contract_invoices.contract_invoices_all
policy|contract_return_matches.crm_all
policy|contracts.contracts_auth_all
policy|cosmo_states.cosmo_states_all
policy|demand_tiers.p_all
policy|dispatch_settings.dispatch_settings_authed
policy|driver_app_version.driver_app_version_read
policy|driver_attendance.driver_attendance_authed
policy|driver_breaks.driver_breaks_authed
policy|driver_events.driver_events_insert_authed
policy|driver_fcm_tokens.fcm_tokens_authed
policy|driver_locations.driver_locations_all
policy|driver_queue_rank.dqr_read
policy|drivers.drivers_authed
policy|eplus_pos.eplus_pos_all
policy|eplus_sales.eplus_sales_r
policy|eplus_supplies.eplus_supplies_r
policy|erp_expense_hide_rules.erp_expense_hide_rules_anon_all
policy|erp_expenses.erp_expenses_auth_all
policy|imported_sales.public insert imported_sales
policy|imported_sales.public read imported_sales
policy|imported_sales.public update imported_sales
policy|instructions.instructions_all
policy|integration_branch_stores.ibs_read
policy|integration_branch_stores.ibs_write
policy|integration_data.id_read
policy|integration_data.id_write
policy|integration_endpoints.ie_read
policy|integration_endpoints.ie_write
policy|jard_audit_log.public insert
policy|jard_audit_log.public read
policy|jard_checkins.jard_checkins_read
policy|jard_excluded_codes.jard_excluded_all
policy|jard_fastmove_codes.public read
policy|jard_fastmove_codes.public write
policy|jard_settings.public read
policy|jard_settings.public write
policy|known_item_codes.anon_all_known_codes
policy|material_prices.material_prices_all
policy|missing_items.missing_anon_all
policy|monthly_sales.ms_all
policy|notification.notification_anon_all
policy|offers.offers_all
policy|order_logs.order_logs_authed
policy|order_selections.p_all
policy|order_store_override.order_store_override_delete
policy|order_store_override.order_store_override_insert
policy|order_store_override.order_store_override_read
policy|order_store_override.order_store_override_update
policy|order_transfer_pending.anon_all_otp
policy|orders.orders_authed
policy|org_settings.anon_read_org
policy|org_settings.anon_write_org
policy|overstock_exclusions.oex_all
policy|page_permissions.Allow public read on page_permissions
policy|pos_branch_opening.pos_branch_opening_all
policy|pos_manual_transfers.pos_manual_transfers_all
policy|pos_methods.allow_all
policy|pos_shift_lines.allow_all
policy|pos_shifts.pos_shifts_auth_all
policy|pos_wallet_transfers.pos_wallet_transfers_auth_all
policy|problem_occurrences.p_all
policy|problem_responsible_roles.p_all
policy|problems.p_all
policy|purchase_orders_flat.p_all
policy|purchase_settings.p_all
policy|region_names.region_names_authed
policy|regions.regions_authed
policy|returns_log.returns_log_read
policy|role_permissions.role_permissions_authed
policy|route_regions.route_regions_authed
policy|routes.routes_authed
policy|sales_analysis_access.sales_analysis_access_all
policy|sales_discount_reviews.sales_discount_reviews_all
policy|sales_items.sales_items_auth_all
policy|sales_returns.sales_returns_read
policy|stock_flat.stock_flat_read
policy|stock_limit.stock_limit_all
policy|store_item_prices.sip_all
policy|store_sheet_mappings.p_all
policy|stores.p_all
policy|supplier_balance_exclusions.supbal_excl_all
policy|supplier_balance_notes.sbn_authenticated
policy|supplier_balance_runs.supbal_runs_insert
policy|supplier_balance_runs.supbal_runs_select
policy|supplier_balance_settings.supbal_settings_insert
policy|supplier_balance_settings.supbal_settings_select
policy|supplier_balance_settings.supbal_settings_update
policy|supplier_balance_snapshots.supbal_snap_insert
policy|supplier_balance_snapshots.supbal_snap_select
policy|supplier_collection_returns.scr_authenticated
policy|supplier_collections.supplier_collections_authenticated
policy|supplier_movement_reviews.smr_all
policy|tab_permissions.tab_permissions_read
policy|task.task_anon_all
policy|task_assignee.task_assignee_all
policy|task_done.task_done_all
policy|tasks.tasks_all
policy|trip_logs.trip_logs_authed
policy|trip_orders.trip_orders_authed
policy|trips.trips_authed
policy|wallet.wallet_auth_read
policy|wallet.wallet_auth_update
policy|wallet_sms.Allow public insert on wallet_sms
policy|wallet_sms.Allow public read on wallet_sms
policy|wallet_sms.Allow public update on wallet_sms
$D2$, E'\n')) l where l <> '';

-- ═══════════════════════════════════════════════════════════════════
--  المقارنة — بيطلّع الفرق فقط
-- ═══════════════════════════════════════════════════════════════════
create temp view srv_obj as
  select 'table' as kind, c.relname::text as name,
         left(md5(string_agg(a.attname::text, ',' order by a.attname)),8) as fp
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = 'public' and c.relkind = 'r'
  group by c.relname
  union all select 'view', viewname::text, '' from pg_views where schemaname = 'public'
  union all select 'trigger', c.relname::text||'.'||t.tgname::text, ''
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and not t.tgisinternal
  union all select 'func', p.proname::text||'/'||p.pronargs::text, ''
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      -- دوال الامتدادات (pg_trgm وغيره) مستثناة من الجهتين — مش شغلنا
      and not exists (select 1 from pg_depend d
                      where d.objid = p.oid and d.deptype = 'e'
                        and d.classid = 'pg_proc'::regclass)
  union all select 'policy', tablename::text||'.'||policyname::text, ''
    from pg_policies where schemaname = 'public';

\echo '════ ناقص على السيرفر (موجود في البرودكشن) ════'
select p.kind as "النوع", p.name as "الاسم"
from prod_obj p
where not exists (select 1 from srv_obj s where s.kind = p.kind and s.name = p.name)
order by p.kind, p.name;

\echo '════ زيادة على السيرفر (مش في البرودكشن) ════'
-- ملحوظة: دوال امتدادات (pg_trgm وغيره) بتتركّب في public على السيرفر
-- الذاتي وبتظهر هنا كزيادة — دي طبيعية ومش محتاجة أي إجراء.
select s.kind as "النوع", s.name as "الاسم"
from srv_obj s
where not exists (select 1 from prod_obj p where p.kind = s.kind and p.name = s.name)
order by s.kind, s.name;

\echo '════ جداول موجودة في الاتنين بس أعمدتها مختلفة ════'
select p.name as "الجدول", p.fp as "بصمة البرودكشن", s.fp as "بصمة السيرفر"
from prod_obj p
join srv_obj s on s.kind = p.kind and s.name = p.name
where p.kind = 'table' and p.fp <> s.fp
order by p.name;
