/* ════════════════════════════════════════════════════════════════
   رجوع «مراجعة الأسعار» لنسختها الأصلية — بقرار المالك
   (2026-11-22، إلغاء لـmigrate_226)
   ----------------------------------------------------------------
   migrate_226 كان ضاف للدالة: `ratio` و`diff_kind` (تعديل سعر /
   اختلاف وحدة / محتاج فحص) و`device` و`itm_qty`، وغيّر الترتيب
   عشان يحطّ تعديل السعر الحقيقي فوق. والشاشة كانت بتخفي اختلافات
   الوحدة افتراضيًا.

   **المالك طلب التبويب يرجع كما كان بالظبط** — فرجّعنا التوقيع
   (14 عمود) والمنطق والترتيب الأصلي `abs(price_diff) desc`.
   والشاشة رجعت من git لنسخة ما قبل التعديل.

   ملف migrate_226 متسابب في المجلد **كسجل** — اتطبّق فعلًا ثم
   اتلغى، فمسحه كان هيخفي إن ده حصل.

   ℹ️ الملاحظة اللي اتبنى عليها 226 لسه صحيحة لو احتجناها بعدين:
   الرقم الخام بيخلط **اختلاف الوحدة** بتعديل السعر (سرنجة 10سم
   اتباعت بـ4 والكتالوج 100 = سرنجة مقابل علبة 25). الفصل بالنسبة
   (الكتالوج ÷ السعر): قريبة من 1 = نفس الوحدة، مضاعف صحيح ≥2 =
   وحدة مختلفة. على بيانات 30 يوم: 173 تعديل حقيقي (−4,614 ج) مقابل
   54 اختلاف وحدة و48 محتاج فحص.
   ════════════════════════════════════════════════════════════════ */

drop function if exists public.sales_price_review(timestamptz, timestamptz, text);

create or replace function public.sales_price_review(
  p_from timestamptz default null,
  p_to   timestamptz default null,
  p_store text default null
) returns table(
  id bigint, bill_no text, bill_date timestamptz, store_name text, employee_name text,
  cust_code text, cust_name text, itm_code text, itm_name_ar text,
  unit_name text, unit_kind text, unit_price numeric, stock_unit_price numeric, price_diff numeric
)
language sql stable security definer set search_path = public
as $function$
  with retl as (
    select bill_no, itm_code, unit_ar, sum(back_qty) bq
    from public.returns_log group by 1,2,3
  )
  select si.id, si.bill_no, si.bill_date, si.store_name, si.employee_name,
         si.cust_code, si.cust_name, si.itm_code, si.itm_name_ar,
         si.unit_name, si.unit_kind, si.unit_price, si.stock_unit_price, si.price_diff
  from public.sales_items si
  left join retl rl on rl.bill_no=si.bill_no and rl.itm_code=si.itm_code and coalesce(rl.unit_ar,'')=coalesce(si.unit_name,'')
  where si.price_mismatch and (not si.price_reviewed)
    and (rl.bq is null or rl.bq < si.itm_qty or si.itm_qty<=0)
    and (p_from is null or si.bill_date >= p_from) and (p_to is null or si.bill_date < p_to)
    and (p_store is null or si.store_name = p_store)
  order by abs(si.price_diff) desc, si.bill_date desc;
$function$;

revoke all on function public.sales_price_review(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.sales_price_review(timestamptz, timestamptz, text) to authenticated;

notify pgrst, 'reload schema';
