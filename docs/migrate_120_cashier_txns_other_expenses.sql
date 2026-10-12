-- migrate_120_cashier_txns_other_expenses.sql
-- تصحيح مزامنة حركات نقاط البيع (cashier_txns): النوع 5 (fh_from_type/fh_to_type=5)
-- = «أخرى» = جدول Other_Expenses في eplus (مصروفات نقطة البيع)، مش F_Account_Chart.
-- كانت المزامنة بتعمل JOIN F_Account_Chart لأي نوع NOT IN (1,2,3,8) فبتلتقط النوع 5
-- غلط (الأرقام اتصادفت في الجدولين بأسماء مختلفة: oe_id=65=«مياه» بينما ac_id=65=«تكلفة المبيعات»).
-- الحل: JOIN Other_Expenses للنوع 5 + استثناء 5 من شرط F_Account_Chart.
-- يُطبّق على القاعدتين. المزامنة بتكتب على السحابة (الذاتي للتطابق فقط).

update public.sync_jobs
set steps = $json$[{"select":"SELECT '{branch}' AS branch, h.fh_id, h.fh_actual_date AS actual_date, h.fh_trans_type2 AS tt2, h.fh_value AS amount, h.fh_computer AS computer, h.fh_from_type AS from_type, h.fh_from_id AS from_id, h.fh_to_type AS to_type, h.fh_to_id AS to_id, COALESCE(cuf.cust_name_ar, vef.ven_name_ar, csf.fcs_name_ar, oef.oe_name_ar, acf.ac_name_ar) AS from_name, COALESCE(cut.cust_name_ar, vet.ven_name_ar, cst.fcs_name_ar, oet.oe_name_ar, act.ac_name_ar) AS to_name, e.e_Name AS user_name, CASE WHEN sv.svi_id IS NOT NULL THEN 1 ELSE 0 END AS is_visa, bk.bnk_name_ar AS channel, sv.visa_value AS visa_value, h.fh_notes AS notes FROM F_Transaction_Header h LEFT JOIN sales_visa_info sv ON sv.fh_id=h.fh_id LEFT JOIN Bank bk ON bk.bnk_id=sv.visa_bank_id LEFT JOIN Customer cuf ON cuf.cust_id=h.fh_from_id AND h.fh_from_type IN (1,8) LEFT JOIN Vendor vef ON vef.ven_id=h.fh_from_id AND h.fh_from_type=2 LEFT JOIN F_Cash_Store csf ON csf.fcs_id=h.fh_from_id AND h.fh_from_type=3 LEFT JOIN Other_Expenses oef ON oef.oe_id=h.fh_from_id AND h.fh_from_type=5 LEFT JOIN F_Account_Chart acf ON acf.ac_id=h.fh_from_id AND h.fh_from_type NOT IN (1,2,3,5,8) LEFT JOIN Customer cut ON cut.cust_id=h.fh_to_id AND h.fh_to_type IN (1,8) LEFT JOIN Vendor vet ON vet.ven_id=h.fh_to_id AND h.fh_to_type=2 LEFT JOIN F_Cash_Store cst ON cst.fcs_id=h.fh_to_id AND h.fh_to_type=3 LEFT JOIN Other_Expenses oet ON oet.oe_id=h.fh_to_id AND h.fh_to_type=5 LEFT JOIN F_Account_Chart act ON act.ac_id=h.fh_to_id AND h.fh_to_type NOT IN (1,2,3,5,8) LEFT JOIN Employee e ON e.e_id=(CASE WHEN ISNUMERIC(h.sec_insert_uid)=1 THEN CAST(h.sec_insert_uid AS int) ELSE NULL END)","target":"cashier_transactions","conflict":"branch,fh_id","probe_max":"SELECT MAX(fh_id) FROM F_Transaction_Header","where_new":"h.fh_id > {last_pth}","where_window":"h.sec_insert_date >= '{cut}' OR h.sec_update_date >= '{cut}'"}]$json$::jsonb
where id='cashier_txns';

-- إعادة سحب آخر ~400 معاملة لكل فرع عشان الصفوف المخزّنة بالاسم الغلط تتصحّح بالـupsert
-- (الشيفت الحالي داخل النطاق ده؛ المحرّك هيعيد السحب في أول نبضة بالـselect الجديد).
update public.sync_branch_state
set last_pth = greatest(0, last_pth - 400)
where job_id = 'cashier_txns';
