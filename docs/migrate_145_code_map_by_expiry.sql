/* ============================================================
   قاموس أكواد المشتريات: التفرقة بتاريخ الصلاحية
   ------------------------------------------------------------
   يصحّح migrate_144. اقرا القصة كلها عشان ماحدش يرجّع الغلط:

   المشكلة الأصلية: المطابقة بـ(الفرع + المسلسل + السعر + الكمية).
   صنفين في نفس الفاتورة بنفس الكمية والسعر (شامبو وبلسم بنفس
   التسعيرة) = سطر الإكسل يلاقي سطرين، فالدالة ترفض الاتنين عشان
   ماتخمّنش. ٦٬٦٧١ بند من ١٣٬٠٤٢ بلا كود كانوا لنفس السبب.

   ❌ المحاولة الأولى (migrate_144): المطابقة بترتيب السطر.
      **غلط** — ترتيب الملف مش مضمون. اتأكد على seyouf/349:
        الملف : كانتو كير · كافلون · شامبو · بلسم · اسبراي
        عندنا : كافلون · بلسم · شامبو · كانتو كير · اسبراي
      التقرير اتصدّر وهو مرتّب بعمود «الكمية»، فالترتيب اختلف.
      الحارس (السعر+الكمية) رفض ٣ من ٥ فمحصلش ضرر، بس الطريقة
      نفسها كانت بتفتح باب إن توأمين يتبدلوا من غير ما حد يكشف.

   ✅ الصح: **تاريخ الصلاحية**. موجود في الملف (عمود ١٥، رقم إكسل
      تسلسلي) وموجود عندنا في `exp_date`، وثابت مهما اتغيّر الترتيب.
      نفس الفاتورة: الشامبو 2030-01-01 والبلسم 2029-01-01 — التوأمين
      اتفرقوا.

   ⚠️ لو الصلاحية فاضية في أي ناحية، بنرجع لـ(السعر+الكمية) بالحرف —
      ماننقصش وصول عن الطريقة القديمة أبدًا. ولو فضل الالتباس
      (توأمين بنفس الصلاحية كمان) الحارس القديم بيرفض الاتنين، وده
      المطلوب: «مش موجود» أحسن من كود غلط.

   ⚠️ `line_no` فضل في جدول الاستقبال **للتشخيص بس** — ممنوع
      المطابقة بيه.
   ============================================================ */
alter table public.purchase_xlsx_stage
  add column if not exists exp_date date;

comment on column public.purchase_xlsx_stage.exp_date is
  'تاريخ الصلاحية من الملف — مفتاح التفرقة بين أصناف نفس الفاتورة المتساوية في السعر والكمية.';
comment on column public.purchase_xlsx_stage.line_no is
  '⚠️ ترتيب السطر في الملف — للتشخيص فقط. ترتيب التصدير غير مضمون (بيتغيّر بترتيب الأعمدة في eplus) فممنوع المطابقة بيه.';

create or replace function public.build_purchase_code_map()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_mapped int; v_applied int;
begin
  with j as (
    select distinct pi.branch, pi.itm_id, s.code, s.name
      from purchase_xlsx_stage s
      join purchase_invoice_items pi
        on pi.branch = s.branch and pi.pth_id = s.pth_id
       and round(pi.itm_pur_price::numeric, 2) = round(s.pur::numeric, 2)
       and round(pi.qnty::numeric)             = round(s.qty::numeric)
       /* الصلاحية بتفرّق بين التوائم. لو ناقصة في أي ناحية بنسيبها
          تعدّي — عشان ما نخسرش أي مطابقة كانت بتنجح قبل كده. */
       and (s.exp_date is null or pi.exp_date is null or s.exp_date = pi.exp_date)
  ),
  /* الحارس: صنف طلع له أكتر من كود محتمل = مايتكوّدش.
     «مش موجود» أأمن من كود غلط. */
  good as (
    select branch, itm_id from j group by branch, itm_id having count(distinct code) = 1
  )
  insert into item_code_map(branch, itm_id, itm_code, itm_name, source)
  select j.branch, j.itm_id, max(j.code), max(j.name), 'purchase_xlsx'
    from j join good g on g.branch = j.branch and g.itm_id = j.itm_id
   group by j.branch, j.itm_id
  on conflict (branch, itm_id) do update
    set itm_code = excluded.itm_code, itm_name = excluded.itm_name, updated_at = now();
  get diagnostics v_mapped = row_count;

  v_applied := apply_item_code_map();
  truncate public.purchase_xlsx_stage;
  return jsonb_build_object('mapped', v_mapped, 'applied', v_applied);
end$function$;
