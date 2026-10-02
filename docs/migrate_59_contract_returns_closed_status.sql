-- ═══════════════════════════════════════════════════════════════════
-- مرتجعات التعاقد: حالة تالتة «مقفول» + قفل المرتجعات القديمة
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- الطلب: قفل كل المرتجعات المعلّقة قبل 2026-10-01 عشان تتشال من
-- الشاشة، **من غير** تسجيل رقم فاتورة.
--
-- ⚠️ وده ماكانش ينفع بالحالات الموجودة، والقاعدة نفسها بتمنعه:
--     crm_invoice_required_chk:
--       CHECK (status <> 'مقابل فاتورة' OR invoice_bill_no IS NOT NULL)
--     crm_status_chk:  CHECK (status IN ('مقابل فاتورة','رصيد'))
--   الحارس الأول محطوط بالقصد: يمنع صف يدّعي «مقابل فاتورة» من غير ما
--   يقول أنهي فاتورة. وشيله كان هيخلّي 635 صف يدّعوا ربط مش موجود.
--
--   و«رصيد» معناها «المرتجع اتحسب رصيد للعميل» — إقرار محاسبي على
--   ~398 ألف ماحصلش.
--
-- الحل: حالة تالتة **«مقفول»** = اتقفل إداريًا، لا ربط ولا احتساب
--   رصيد. بتحقّق الغرض (يتشال من قايمة المعلّق) من غير أي ادّعاء،
--   وبتفضل قابلة للفك (unmatch_contract_return بتحذف الصف).
--
-- ⚠️ ملحوظة تشغيلية: العملية اتعملت والمستخدم «محمد مجدى» بيربط
--   مرتجعات يدويًا في نفس الوقت (آخر ربط ليه 02:03، والقفل 02:09).
--   ماتأثرش شغله: الإدخال على `match_status = 'قيد الانتظار'` بس،
--   وقبل أكتوبر بس، ومعاه ON CONFLICT DO NOTHING.
--
-- النتيجة: 635 مرتجع اتقفلوا (سبتمبر 321 · أغسطس 313 · يوليو 1)،
--   وأكتوبر ماتلمسش (3 معلّق + 17 مربوط، كلهم شغل يدوي).
-- ═══════════════════════════════════════════════════════════════════

alter table public.contract_return_matches drop constraint if exists crm_status_chk;
alter table public.contract_return_matches add constraint crm_status_chk
  check (status = any (array['مقابل فاتورة'::text, 'رصيد'::text, 'مقفول'::text]));

comment on constraint crm_status_chk on public.contract_return_matches is
  'مقابل فاتورة = مربوط بفاتورة بعينها (لازم invoice_bill_no — شوف crm_invoice_required_chk). '
  'رصيد = اتحسب رصيد للعميل. '
  'مقفول = اتقفل إداريًا من غير ربط ولا احتساب رصيد (مرتجعات قديمة).';


-- ── قفل المرتجعات المعلّقة قبل أكتوبر ────────────────────────────
-- matched_by مميّز عشان ينفع تتفك كلها بأمر واحد:
--   delete from contract_return_matches
--    where matched_by = 'قفل جماعي — مرتجعات قبل 2026-10-01';
insert into public.contract_return_matches
  (return_bill_no, return_branch, status, return_value, matched_by, matched_at)
select r.return_bill_no, nullif(r.return_branch,''), 'مقفول', r.total_value,
       'قفل جماعي — مرتجعات قبل 2026-10-01', now()
  from public.get_contract_returns('') r
 where r.match_status = 'قيد الانتظار'
   and r.return_date < '2026-10-01'
on conflict (return_bill_no, coalesce(return_branch,'')) do nothing;


-- ── الفحص ────────────────────────────────────────────────────────
select to_char(return_date at time zone 'Africa/Cairo','YYYY-MM') as الشهر,
       count(*) as إجمالي,
       count(*) filter (where match_status='قيد الانتظار') as قيد_الانتظار,
       count(*) filter (where match_status='مقفول')        as مقفول,
       count(*) filter (where match_status='مقابل فاتورة') as مقابل_فاتورة,
       count(*) filter (where match_status='رصيد')         as رصيد
  from public.get_contract_returns('')
 group by 1 order by 1 desc;
