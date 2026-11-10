-- migrate_202_visa_name_and_bill.sql
--
-- إضافة «الإسم» و«رقم الفاتورة» لحركات الفيزا في شاشة مراجعة الشيفت.
--
-- الطلب: شاشة «يتطلب مراجعة» بتعرض حركة فيزا بلا تفسير من غير أي خيط
-- يرجّعها للبيعة. تقرير eplus «تحصيل بطاقات إئتمان» فيه الأعمدة دي.
--
-- فحص المصدر مباشرة على Genius (قراءة فقط، 60 يوم، 6,065 حركة):
--   sales_visa_info.sth_id    = رقم فاتورة البيع — مليان 100% (= bill_no عندنا)
--   sales_visa_info.visa_name = «الإسم» — 26% بس مش '0'، والباقي مهمل.
--     المالك أكّد إنه مطلوب: الكاشير بيستخدم الخانة دي كملاحظة حرة
--     (رقم فاتورة، تعليق، أي حاجة).
--   sales_visa_info.cust_id   = العميل الحقيقي (78%) — مش مطلوب دلوقتي.
--
-- ⚠️ «تحصيل» مش موجود كعلامة لكل حركة في eplus. اتدوّر عليه في كل
-- القاعدة: مفيش جدول بيشاور على svi_id، temp_col1 فاضي في 6,067 صف،
-- و F_Transaction_Header_Ext.fhe_paper_get_date فاضي خالص.
-- الموجود Shift_Changes_d.scd_d_visacollect وده مبلغ للوردية كلها.
-- متأجّل لحد ما المالك يوضّح المقصود.

alter table public.cashier_transactions
  add column if not exists visa_name text,
  add column if not exists sth_id    bigint;

comment on column public.cashier_transactions.visa_name is
  'sales_visa_info.visa_name — خانة حرة الكاشير بيكتب فيها ملاحظة/رقم فاتورة';
comment on column public.cashier_transactions.sth_id is
  'sales_visa_info.sth_id — رقم فاتورة البيع في eplus (= bill_no عندنا)';

-- المزامنة: نضيف العمودين للـSELECT بتاع «حركات نقاط البيع».
-- المحرّك بيطابق أعمدة الناتج بأسماء أعمدة الهدف، فالإضافة كفاية.
update public.sync_jobs
   set steps = replace(
         steps::text,
         'sv.visa_value AS visa_value, sv.visa_no AS visa_no, h.fh_notes AS notes',
         'sv.visa_value AS visa_value, sv.visa_no AS visa_no, sv.visa_name AS visa_name, sv.sth_id AS sth_id, h.fh_notes AS notes'
       )::jsonb,
       updated_at = now()
 where steps::text like '%cashier_transactions%'
   and steps::text like '%sv.visa_no AS visa_no, h.fh_notes AS notes%';

notify pgrst, 'reload schema';
