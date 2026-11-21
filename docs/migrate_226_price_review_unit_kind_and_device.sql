/* ════════════════════════════════════════════════════════════════
   مراجعة الأسعار: تمييز اختلاف الوحدة عن تعديل السعر + الجهاز
   (2026-11-21)
   ----------------------------------------------------------------
   سؤال المالك: «لو تم تعديل سعر بيع صنف في فاتورة، تقدر توصل له؟»
   الإجابة أيوة — `sales_items` بتخزّن السعر المتقاضى وسعر الكتالوج
   **مجمّد وقت الإدراج**، فالفرق محسوب. بس الرقم الخام **مضلّل**.

   ── ليه الرقم الخام مضلّل ───────────────────────────────────────
   في 30 يوم للمعمورة: 312 سطر «فرق سعر» بـ17,064 ج. لما بصينا:
     «سرنجة 10سم اتباعت بـ4 والكتالوج 100»  ← سرنجة مقابل علبة 25
     «بيبي جوي اتباع بـ8.23 والكتالوج 180»  ← حفاضة مقابل باكو
   دي **اختلاف وحدة** مش تلاعب. التصنيف بالنسبة (الكتالوج ÷ السعر):
     173 سطر نسبتهم 1.04–1.59  → تعديل سعر حقيقي  (−4,614 ج)
      54 سطر مضاعف صحيح 2–25   → اختلاف وحدة      (−5,631 ج)
      48 سطر نسبتهم لحد 159    → محتاج فحص يدوي   (−6,819 ج)
   يعني التلاعب المرشّح **رُبع** الرقم الخام. لو عرضنا الخام كنا
   هنوجّه المالك على 12 ألف جنيه أغلبهم وهم.

   ── الجهاز ─────────────────────────────────────────────────────
   `sales_items` مافيهاش عمود جهاز. بنستنتجه من **حركة إقفال
   الفاتورة** في `cashier_transactions` (فيها `computer`)، بالربط
   بـ`sth_id` أو رقم الفاتورة في الملاحظات، ونافذة يوم قبل/بعد
   للفاتورة الليلية. نسبة التعرّف المقاسة **95%** (36 من 38).
   ⚠️ ده **استنتاج مش تسجيل** — لو الفاتورة مااتقفلتش بحركة واضحة
      العمود بيرجع فاضي، ومابيساويش دليل على مين عدّل السعر.

   ── حدود لازم تتقال ────────────────────────────────────────────
   الدالة بتشوف **الأثر مش الفعل**: مفيش في النظام سجل «فلان غيّر
   السعر الساعة كذا». فلو السعر اتعدّل ورجع، أو الكتالوج نفسه اتغيّر
   بعد البيع، المقارنة بتختلف. وسعر الكتالوج نفسه ممكن يكون غلط
   («فرشاة أسنان بـ1,150 ج» كتالوج مشكوك فيه مش بيع رخيص).

   التوقيع اتغيّر (أعمدة جديدة) فمحتاج drop قبل create.
   الأداء: 349 مللي للشهر. ومحدش بينادي الدالة غير تبويب «مراجعة
   الأسعار» في `delivery/pages/reports.html`.
   يتطبّق على السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

drop function if exists public.sales_price_review(timestamptz, timestamptz, text);

create or replace function public.sales_price_review(
  p_from timestamptz default null,
  p_to   timestamptz default null,
  p_store text default null
) returns table(
  id bigint, bill_no text, bill_date timestamptz, store_name text, employee_name text,
  cust_code text, cust_name text, itm_code text, itm_name_ar text,
  unit_name text, unit_kind text, itm_qty numeric,
  unit_price numeric, stock_unit_price numeric, price_diff numeric,
  ratio numeric, diff_kind text, device text
)
language sql stable security definer set search_path = public
as $function$
  with retl as (
    select bill_no, itm_code, unit_ar, sum(back_qty) bq
      from public.returns_log group by 1,2,3
  ),
  base as (
    select si.id, si.bill_no, si.bill_date, si.store_name, si.employee_name,
           si.cust_code, si.cust_name, si.itm_code, si.itm_name_ar,
           si.unit_name, si.unit_kind, si.itm_qty,
           si.unit_price, si.stock_unit_price, si.price_diff,
           case when coalesce(si.unit_price,0) > 0 and si.stock_unit_price is not null
                then round(si.stock_unit_price / si.unit_price, 3) end as ratio
      from public.sales_items si
      left join retl rl
        on rl.bill_no = si.bill_no and rl.itm_code = si.itm_code
       and coalesce(rl.unit_ar,'') = coalesce(si.unit_name,'')
     where si.price_mismatch and (not si.price_reviewed)
       and (rl.bq is null or rl.bq < si.itm_qty or si.itm_qty <= 0)
       and (p_from is null or si.bill_date >= p_from)
       and (p_to   is null or si.bill_date <  p_to)
       and (p_store is null or si.store_name = p_store)
  )
  select b.id, b.bill_no, b.bill_date, b.store_name, b.employee_name,
         b.cust_code, b.cust_name, b.itm_code, b.itm_name_ar,
         b.unit_name, b.unit_kind, b.itm_qty,
         b.unit_price, b.stock_unit_price, b.price_diff, b.ratio,
         case
           when b.ratio is null                                        then 'check'
           when b.ratio >= 0.6 and b.ratio <= 1.6                      then 'price_edit'
           when b.ratio >= 2 and abs(b.ratio - round(b.ratio)) < 0.12  then 'unit'
           else 'check'
         end as diff_kind,
         d.dev as device
    from base b
    left join lateral (
      select string_agg(distinct c.computer, ' / ') as dev
        from public.cashier_transactions c
        join public.branches br on br.code = c.branch
       where b.store_name = any (coalesce(br.aliases, array[]::text[]))
         and c.computer is not null
         and c.actual_date >= ((b.bill_date at time zone 'Africa/Cairo')::date - 1)::timestamp
         and c.actual_date <  ((b.bill_date at time zone 'Africa/Cairo')::date + 2)::timestamp
         and (c.sth_id::text = b.bill_no
              or substring(c.notes from 'رقم\s*([0-9]+)') = b.bill_no)
    ) d on true
   order by
     case when b.ratio is not null and b.ratio >= 0.6 and b.ratio <= 1.6 then 0 else 1 end,
     abs(b.price_diff) desc, b.bill_date desc;
$function$;

revoke all on function public.sales_price_review(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.sales_price_review(timestamptz, timestamptz, text) to authenticated;

notify pgrst, 'reload schema';
