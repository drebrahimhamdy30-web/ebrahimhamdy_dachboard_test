-- migrate_107_sync_use_map.sql
-- المزامنة تستعمل القاموس (item_code_map) لتكويد الصفوف الجديدة بدل الإثراء القديم
-- (enrich_purchase_item_names) اللي كان بيطابق itm_id=كود المخزون غلط (تصادم أرقام).
-- post_rpc للمهمة بقى apply_item_code_map: يملأ itm_code+itm_name من القاموس لأي بنود جديدة.
-- الأصناف اللي مش في القاموس تفضل بلا كود (محتاجة شيت) — وده الصح. يُطبّق على القاعدتين.

update public.sync_jobs set post_rpc = 'apply_item_code_map', updated_at = now()
where id = 'purchases';

-- apply_item_code_map تُستدعى من المحرّك (service_role) بعد كل مزامنة
grant execute on function public.apply_item_code_map() to service_role;

notify pgrst, 'reload schema';
