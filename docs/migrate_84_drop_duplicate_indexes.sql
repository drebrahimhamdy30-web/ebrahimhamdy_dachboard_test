-- migrate_84_drop_duplicate_indexes.sql
-- حذف فهارس مكررة (نفس الأعمدة) اكتشفها مستشار أداء Supabase — تنظيف هامشي.
-- نسيب الفهرس المربوط بقيد/الأساسي ونحذف المكرر الزائد:
--  branches: نسيب branches_name_key (قيد UNIQUE + هدف FK) ونحذف branches_name_uniq.
--  purchase_invoice_items: نسيب idx_pii_code ونحذف ix_pii_itm_code (الاتنين على itm_code).
-- CONCURRENTLY = من غير قفل؛ شغّل بـpsql مباشرة (مش جوّه transaction).
-- يُطبَّق على القاعدتين: السحابة (اتعملت) + السيرفر الذاتي.

drop index concurrently if exists public.branches_name_uniq;
drop index concurrently if exists public.ix_pii_itm_code;
