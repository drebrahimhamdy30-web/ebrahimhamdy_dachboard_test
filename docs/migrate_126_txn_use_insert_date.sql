-- migrate_126_txn_use_insert_date.sql
-- توقيت حركات نقاط البيع: استعمال sec_insert_date بدل fh_actual_date.
--
-- السبب: بعض المعاملات (خصوصًا توريد نقدي من bm/visa لنقطة البيع لتمويل دفعات الموردين)
-- عندها fh_actual_date مزاح 12 ساعة (AM/PM غلط): مثال fh 1581733 توريد 97,190
--   fh_actual_date = 04:57ص  (غلط)   مقابل   sec_insert_date = 16:57م (الصح).
-- فالتوريد كان بيقع برّه نافذة الشيفت والصرف المطابق جوّها → صرف بلا توريد →
-- «صافي الكاش» بيطلع سالب ضخم. كشف حساب eplus نفسه بيستعمل sec_insert_date.
--
-- الحل: actual_date = h.sec_insert_date (التوقيت الموثوق الموحّد). + إعادة سحب للتصحيح.
-- يُطبّق على السحابة (بيانات الحركات هناك).

update public.sync_jobs
set steps = jsonb_set(steps, '{0,select}', to_jsonb(
  replace(steps->0->>'select', 'h.fh_actual_date AS actual_date', 'h.sec_insert_date AS actual_date')))
where id = 'cashier_txns';

-- إعادة سحب آخر ~2500 معاملة لكل فرع لتصحيح التوقيت المخزّن (الشيفتات الأخيرة)
update public.sync_branch_state set last_pth = greatest(0, last_pth - 2500) where job_id = 'cashier_txns';
