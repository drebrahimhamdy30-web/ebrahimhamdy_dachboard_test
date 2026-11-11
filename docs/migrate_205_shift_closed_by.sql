-- ═══════════════════════════════════════════════════════════════════
--  اسم الموظف اللي قفل الشيفت
-- ═══════════════════════════════════════════════════════════════════
--  eplus بتمسك **اتنين** في `Shift_Changes`، والفرق بينهم حقيقي مش
--  نظري: 2,875 من 13,702 صف في المعمورة (21%) العمودين فيهم مختلفين.
--
--    sec_insert_uid  →  «المستخدم»        ← اللي نفّذ الإقفال  ← المطلوب
--    sc_to_employee  →  «الموظف المستلم»  ← اللي استلم الدرج   ← اللي كنا بناخده
--
--  ⚠️ عيّنة الخمس صفوف الأولى كانت **مضللة**: العمودين فيها متساويين
--     (الشيفت اللي بيقفله نفس الشخص). لولا العدّ على الجدول كله كنا
--     هنربط كل شيفت باسم غلط في 21% من الحالات.
--
--  والتسمية اتأكدت من **تقرير eplus نفسه** («تقرير تسليم الدرج»):
--     4 نوفمبر 04:38 ص — المستخدم: اسماعيل نبيل شحاته
--                        الموظف المستلم: د محمد مبارك
--     والقاعدة بتقول sec_insert_uid=اسماعيل و sc_to_employee=محمد مبارك.
--     مطابق بالحرف، فالربط مش استنتاج.
--
--  واختبار «سلسلة التسليم» (هل المستلم بيبقى قافل الشيفت اللي بعده؟)
--  طلع **غير حاسم** — 62 مقابل 51 من 222 — فالاعتماد على التقرير.
--
--  ملاحظات تنفيذ:
--  · `sec_insert_uid` عمود **varchar** و`Employee.e_id` رقم، فالربط
--    محروس بـ`ISNUMERIC` — قيمة واحدة غير رقمية كانت هتوقّع استعلام
--    المزامنة كله. (مقيس: 13,702 صف · صفر فاضي · صفر غير رقمي · صفر
--    بلا موظف مطابق.)
--  · `Employee` كمان عندها عمود اسمه `sec_insert_uid` — أي شرط عليه
--    لازم يتأهّل بـ`sc.` وإلا «Ambiguous column name».
--  · اتضاف `where_range` للخطوة عشان سحب الفترة يشتغل — المحرّك
--    بيرفض الـbackfill لأي خطوة تزايدية من غيره (حارس اتحط بعد حادثة
--    1.47 مليون صف).
-- ═══════════════════════════════════════════════════════════════════

alter table public.shift_changes add column if not exists closed_by text;

comment on column public.shift_changes.closed_by is
  'اسم الموظف اللي قفل الشيفت = Employee.e_Name لـ Shift_Changes.sec_insert_uid («المستخدم» في تقرير تسليم الدرج). غير to_emp اللي هو المستلم.';

update public.sync_jobs
set steps = jsonb_build_array(jsonb_build_object(
  'select',
  'SELECT ''{branch}'' AS branch, sc.sc_id, sc.sc_cashier_id AS cashier_id, cs.fcs_name_ar AS point_name, '
  || 'sc.sc_shift_start_time AS shift_start, sc.sc_start_cash AS start_cash, sc.sc_curr_cash AS curr_cash, '
  || 'sc.sc_act_cash AS act_cash, sc.sc_trans_value AS trans_value, sc.sec_insert_date AS closed_at, '
  || 'sc.sc_to_employee AS to_emp, sc.sc_visa_act_count AS visa_count, e.e_Name AS closed_by '
  || 'FROM Shift_Changes sc '
  || 'LEFT JOIN F_Cash_Store cs ON cs.fcs_id = sc.sc_cashier_id '
  || 'LEFT JOIN Employee e ON e.e_id = CASE WHEN ISNUMERIC(LTRIM(RTRIM(sc.sec_insert_uid))) = 1 '
  || 'THEN CAST(LTRIM(RTRIM(sc.sec_insert_uid)) AS decimal(18,0)) END',
  'target',       'shift_changes',
  'conflict',     'branch,sc_id',
  'probe_max',    'SELECT MAX(sc_id) FROM Shift_Changes',
  'where_new',    'sc.sc_id > {last_pth}',
  'where_window', 'sc.sec_insert_date >= ''{cut}'' OR sc.sec_update_date >= ''{cut}''',
  'where_range',  'sc.sec_insert_date >= ''{from}'' AND sc.sec_insert_date < DATEADD(day, 1, ''{to}'')'
)), updated_at = now()
where id = 'shifts';

/* ملء التاريخ القديم (الصفوف الموجودة مابتترجعش بالنافذة العادية —
   نافذتها يومين). بيتنفّذ على الماستر عبر طابور الطلبات:

insert into public.sync_requests(job_id, branch, kind, from_date, to_date)
select 'shifts', b, 'backfill', date '2026-09-01', current_date
from unnest(array['mamora','san','bishr','seyouf']) b;
*/
