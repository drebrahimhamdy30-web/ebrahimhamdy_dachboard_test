-- ═══════════════════════════════════════════════════════════════════
--  فرق **محتوى** الدوال: السيرفر الذاتي مقابل البرودكشن
-- ═══════════════════════════════════════════════════════════════════
--  ليه الملف ده موجود: المقارنة الأولى قارنت **أسماء** الدوال وعدد
--  معاملاتها — فطلعت "مطابقة". لكن شاشة مؤشر الأداء طلعت فاضية في
--  جزء خدمة العملاء، والسبب إن جسم الدالة get_kpi_dashboard اتعدّل
--  على السحابة و migrate_25 اتكتب فيه **وصف** التعديل مش التعديل نفسه.
--  الاسم واحد والمحتوى مختلف — والمقارنة بالأسماء عمياها عن ده.
--
--  ده بيقارن md5 لـ pg_get_functiondef لكل دالة. دوال الامتدادات
--  مستثناة من الجهتين.
--
--  لقطة البرودكشن: 2026-09-19
--
--    cd /root/supabase-project
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/schema_diff_funcbody_vs_prod.sql
-- ═══════════════════════════════════════════════════════════════════

create temp table prod_fn as
select split_part(l,'|',1) as fn, split_part(l,'|',2) as fp
from unnest(string_to_array($FN$
add_recon_txn/6|f43e1dc7
add_review_flag/8|0d9d2432
admin_delete_branch_user/1|699966b8
admin_toggle_branch_user/2|fac31073
admin_upsert_branch_user/9|a3dbf77c
apply_sales_returns/0|57aeeda3
ar_norm/1|0802e2d2
audit_branch_values/0|a280b999
auto_dispatch_tick/1|5199d953
bank_actor/0|4072401f
bank_add_manual/3|38722f55
bank_can_use/0|b881829e
bank_classify/3|3df77609
bank_import_statement/3|6965aee2
bank_post/1|091006fa
bank_set_opening/1|591a2573
bank_set_source/2|82807bd0
best_store_for/2|5b15cb3f
branch_id/1|88e2b0ff
branch_name/1|a67a2f7c
branch_store_name/1|6e453e58
change_branch_user_password/3|b06b0733
change_driver_branch/3|1822d0cb
check_trip_complete/0|0fa8d3cf
ci_freeze_reviewed_total/0|92f682df
cleanup_empty_trips/0|fdbe288c
cleanup_old_logs/0|e59e13d4
close_stale_open_sessions/0|d186d74c
compute_code_suggestions_batch/1|5e245b00
create_password_reset/1|ced4b213
delete_current_wallet_transfer/1|b015c13a
delete_month_sales/1|28723a38
delivery_active_days/3|f126174b
delivery_by_hour/3|4c96507f
difficult_driver_load/1|bfa0fd0a
enrich_sale_row/0|527ee787
ensure_integration_table/4|05a7dc08
get_all_branch_users/0|56007047
get_branch_rep_users/0|49809ea8
get_closure_machine_recon/1|9775c373
get_closure_machine_txns/2|05405a50
get_completed_orders_for_bills/2|fd5aa348
get_consumption_detail/1|6fe4eb11
get_consumption_rates/0|3bcb5916
get_contract_returns/1|e7c1fea5
get_cs_orders/2|e8c51950
get_customer_names/1|e5843ac8
get_driver_emails/0|42c3e709
get_driver_hard_trips_today/2|eeb9e6ed
get_driver_month_stats/1|3db4ac16
get_driver_rank/2|e4f30d9f
get_hard_load/1|47397129
get_hard_trips_month/1|9be67d62
get_hard_trips_today/1|cff1dc1e
get_jard_daily_stats/3|2d7a8087
get_jard_efficiency/3|de15f445
get_jard_full_report/4|e7fd958f
get_kpi_dashboard/2|f4b71151
get_min_stock_alerts/0|707aab87
get_new_items/0|376cb81c
get_open_review_flags/1|29ddf67b
get_pos_balances_at/2|178514a1
get_prep_report/3|2a7e4cc9
get_prev_trip_orders/2|a5ec60fa
get_price_changes/0|e083c146
get_purchase_companies/0|a5466d85
get_purchase_orders/0|a134f5cf
get_role_pages/1|b13ee559
get_role_tabs/1|998b1df3
get_sales_summary/0|791d4d98
get_shortages/1|26d99ee0
get_stock_limits/1|57918c58
get_stock_summary/0|3401ffaf
get_trip_counts/1|4848317b
get_trip_review_flags/1|c66524ed
get_unclosed_orders/1|956daf0e
get_user_branch_map/0|7ad106c2
get_user_name_map/0|e6995b7c
item_balance/2|a73ef4bf
item_lookup/2|9d7be22b
jard_checkin/1|56a9b9e2
jard_counted/3|3b91a3fd
jard_uncounted/3|b66b6208
jwt_all_branches/0|fbb50a62
jwt_app_role/0|9b5c8fc9
jwt_branch/0|860d89dd
jwt_branch_id/0|36c1a7b7
jwt_driver_id/0|3e0d8cdd
jwt_user_id/0|b018eeff
list_public_tables/0|9e942cf0
list_sales_months/0|6da3a836
lookup_customer_name/1|ad4821cf
manager_toggle_driver/2|d030174f
manager_upsert_driver/15|43831ef9
manual_assign_order/3|7e40f442
mark_item_coded/2|2b4f324c
match_contract_return/5|da2537e1
merge_contract_invoices/3|cdf4e449
move_recon_txn/4|66815fb4
notify_driver_order_event/0|ecdc2f25
notify_fcm_on_assign/0|531a2f44
notify_on_driver_change/0|5a3215e0
num_tokens/1|abefc3a1
order_route_tokens/2|c2a3ac3f
pharma_prices_finalize/1|22f9f755
pharma_prices_upsert/1|1ca89ff8
prep_return_to_prep/2|e903fe9e
prevent_assign_to_busy_driver/0|b01c02f4
prevent_duplicate_online/0|2436a42a
prevent_duplicate_trip_order/0|9bb933af
propagate_branch_rename/0|3f3d94d7
protect_locked_region/0|60a9c3fe
quick_search_stock/2|3d7f11a4
rebind_v_stock_units_full/0|1f313dea
recompute_trip_total/1|80d9623e
recover_stuck_orders/0|0767f1c2
refresh_consumption_rates/0|2691ee76
refresh_driver_ranks/1|3facefed
refresh_purchase_orders/0|bef00df5
refresh_stock_flat/0|7303301e
report_conflicting_codes/0|1fa63c26
report_delivered_trip_completed/0|0f843202
report_driver_location/4|4ae702dd
report_shared_codes/0|9bfa5253
req_qty/4|431cc22c
require_app_role/1|d34a8e01
reset_password_with_code/3|15da0401
reset_password_with_token/2|b5215921
resolve_jard_audit/3|6f5691b7
resolve_login_email/1|ddd23505
restore_table_from_json/3|b50b8cf3
review_price_change/2|f9c2ddd3
sales_active_days/3|c5599277
sales_by_day/3|805034cd
sales_by_employee/3|a092330b
sales_by_hour/3|0922fc99
sales_detail/7|2fc1bb88
sales_discount_bills/3|8f55876f
sales_discount_stats/3|0c485dae
sales_overview/3|6d4f20b7
sales_price_review/3|afeb96ce
sales_summary/3|21cb98a4
sales_top_items/4|a92ecfb9
save_page_permission/4|bea78fe9
save_page_permissions_bulk/1|2468c900
save_push_subscription/4|758d2883
save_role_permissions/2|d86038c9
save_tab_permissions_bulk/1|e09d4636
search_stock_items/2|f9105d7a
set_driver_avatar/2|20bab6c6
set_erp_expense_hide_rules_updated_at/0|2a31d7a2
set_erp_expenses_updated_at/0|ae8d3353
set_notification_updated_at/0|078646dd
set_order_region/2|f9f57908
set_return_value/0|6dc86f80
set_stock_limit/5|f7f59283
set_task_updated_at/0|e704a765
sort_letters/1|06adc500
stamp_attendance_branch/0|5bbf014b
store_delete/1|da56d633
store_rename/2|bfa6cf2a
submit_jard_audit/1|123ebc46
suggest_codes_for_names/1|b41fede7
suggest_contract_invoices/6|e9077f8c
suggest_purchase_sources/1|9b6cf953
suggest_stock_codes/2|e256b285
sweep_unrated_perf/0|b3daf9ed
sync_branch_user_to_auth/0|b69ef02f
sync_collection_returns_total/0|c9b55a7f
sync_driver_is_online/0|ecb1699a
sync_page_permission_key/0|285ae231
task_require_item_name/0|6fdc8f57
topup_code_suggestions/0|77e9928e
touch_updated_at/0|32b74c8c
transfer_orders_to_driver/4|e6775bdf
trg_delivery_perf/0|126e71df
trg_fail_perf/0|989fa082
trg_order_gift/0|b1f27e8c
trg_order_gift_release/0|e9a8b0e4
trg_order_hold_failed/0|a8308ae7
trg_order_late_deliver/0|368c522a
trg_order_total_recompute/0|6751c902
trg_order_unlink_on_release/0|3d6e922f
trg_refresh_ranks/0|29d9f385
trg_server_event_time/0|2ea58f64
trg_set_dispatch_type/0|071235ab
trg_sla_rating/0|7c021c3a
trg_trip_complete_cascade/0|1120f817
trg_trip_completed_freeze/0|fba94e3f
trg_trip_driver_last_completed/0|af92c739
trg_trip_return_perf/0|efe23747
trg_trip_stamp_completed/0|023f8f94
trg_triporders_recompute/0|a49511d5
unmatch_contract_return/2|3f1b448d
unmerge_contract_invoice/2|ed5de394
update_last_activated/0|ca3b92b7
update_txn_time/3|4c2d25ac
upload_month_sales/2|dba67a0c
upload_store_sheet/2|fda6b650
vault_secret/1|84ee9660
verify_branch_login/2|bd864a1a
verify_branch_token/1|bc22becd
web_driver_fail_order/8|138f74dc
$FN$, E'\n')) l where l <> '';

create temp view srv_fn as
select p.proname||'/'||p.pronargs as fn, left(md5(pg_get_functiondef(p.oid)),8) as fp
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f'
  and not exists (select 1 from pg_depend d
                  where d.objid = p.oid and d.deptype = 'e'
                    and d.classid = 'pg_proc'::regclass);

\echo '════ دوال محتواها مختلف (الاسم واحد والجسم غير) ════'
select p.fn as "الدالة", p.fp as "البرودكشن", s.fp as "السيرفر"
from prod_fn p join srv_fn s using (fn)
where p.fp <> s.fp
order by p.fn;

\echo '════ دوال ناقصة على السيرفر ════'
select p.fn as "الدالة" from prod_fn p
where not exists (select 1 from srv_fn s where s.fn = p.fn)
order by 1;

\echo '════ دوال زيادة على السيرفر (شغل السيرفر — متوقعة) ════'
select s.fn as "الدالة" from srv_fn s
where not exists (select 1 from prod_fn p where p.fn = s.fn)
order by 1;

\echo '════ الخلاصة ════'
select (select count(*) from prod_fn) as "على البرودكشن",
       (select count(*) from srv_fn) as "على السيرفر",
       (select count(*) from prod_fn p join srv_fn s using (fn) where p.fp = s.fp) as "مطابقة",
       (select count(*) from prod_fn p join srv_fn s using (fn) where p.fp <> s.fp) as "مختلفة";
