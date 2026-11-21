-- ٢٠٤: رفع سقف المهلة على بناء خريطة أكواد المشتريات
--
-- الليه: بعد migrate_203 الرفع وقع بـ57014 «canceling statement due to
-- statement timeout». دور authenticated سقفه ٨ ثوانى (و anon ٣)، وبناء
-- الخريطة على شيت ٢٩ ألف بند بيعمل: مطابقة + upsert ١٣ ألف صف + تصفير
-- الربط المشكوك + تطبيق على ٢٢٦ ألف بند. القياس بعد الدفعة الأولى كان
-- ~٢ ثانية، لكن أول رفعة بعد تغيير القواعد بتعيد كتابة أضعاف ده.
--
-- الحل: SET statement_timeout على مستوى الدالة. **اتأكد بالتجربة** عبر
-- PostgREST الحقيقي مش بالافتراض:
--   دالة بتنام ١١ث بلا SET  → 500 (57014) بعد ٣.٥ث
--   نفسها مع SET '60s'      → 200 بعد ١١.١ث ✓
-- (الاختبار جوّه DO block مابيثبتش حاجة — SET LOCAL مابيعيدش ضبط
--  المؤقّت للجملة اللى شغالة أصلًا، فالاتنين بيعدّوا.)
--
-- ١٢٠ ثانية سقف سخى من غير ما يبقى بلا حدود. الاستيراد عملية يدوية
-- بيعملها المالك مرة كل فترة، مش نداء متكرر — فحجز الاتصال مقبول.
--
-- المهلة على purchase_map_build بس — apply_item_code_map بتتنادى كمان
-- من post_rpc بتاع المزامنة (بيشتغل بـservice_role بلا سقف) فمش محتاجة.

begin;

create or replace function public.purchase_map_build()
returns jsonb language plpgsql security definer
set search_path to 'public'
set statement_timeout to '120s'
as $function$
declare v_mapped int; v_applied int; v_stage int; v_conflict int;
begin
  perform require_page_edit('purchase_invoices');
  select count(*) into v_stage from public.purchase_xlsx_stage;

  create temp table _cand on commit drop as
  with j as (
    select distinct pi.branch, pi.itm_id, btrim(s.code) code, s.name
      from public.purchase_xlsx_stage s
      join public.purchase_invoice_items pi
        on pi.branch = s.branch and pi.pth_id = s.pth_id
       and round(pi.itm_pur_price::numeric, 2) = round(s.pur::numeric, 2)
       and round(pi.qnty::numeric)             = round(s.qty::numeric)
     where coalesce(btrim(s.code), '') <> '' and btrim(s.code) !~ '^0+$'
  ),
  one_code as (
    select branch, itm_id from j group by branch, itm_id having count(distinct code) = 1
  ),
  picked as (
    select j.branch, j.itm_id, max(j.code) code, max(j.name) name
      from j join one_code o on o.branch = j.branch and o.itm_id = j.itm_id
     group by j.branch, j.itm_id
  ),
  one_id as (
    select branch, code from picked group by branch, code having count(*) = 1
  )
  select p.branch, p.itm_id, p.code, p.name,
         (case when o.branch is null then 0 else 1 end) conf
    from picked p
    left join one_id o on o.branch = p.branch and o.code = p.code;

  select count(*) into v_conflict from _cand where conf = 0;

  insert into public.item_code_map(branch, itm_id, itm_code, itm_name, source, confidence)
  select branch, itm_id, code, name, 'purchase_xlsx', conf from _cand
  on conflict (branch, itm_id) do update
    set itm_code   = excluded.itm_code,
        itm_name   = excluded.itm_name,
        confidence = excluded.confidence,
        updated_at = now();
  get diagnostics v_mapped = row_count;

  /* إعادة تقييم التعارض على الجدول كله — الدفعة الجديدة ممكن تولّد
     تعارض مع صف قديم، أو تحلّ تعارض قديم. الاتنين لازم يتمسكوا. */
  update public.item_code_map m set confidence = 0, updated_at = now()
   where m.confidence <> 0
     and exists (select 1 from public.item_code_map m2
                  where m2.branch = m.branch and m2.itm_code = m.itm_code
                    and m2.itm_id <> m.itm_id);

  update public.item_code_map m set confidence = 1, updated_at = now()
   where m.confidence = 0
     and not exists (select 1 from public.item_code_map m2
                      where m2.branch = m.branch and m2.itm_code = m.itm_code
                        and m2.itm_id <> m.itm_id);

  /* الربط المشكوك مايسيبش كود قديم غلط مطبّق على البنود */
  update public.purchase_invoice_items pi
     set itm_code = null, itm_name = null
    from public.item_code_map m
   where m.branch = pi.branch and m.itm_id = pi.itm_id and m.confidence = 0
     and pi.itm_code is not null;

  v_applied := public.apply_item_code_map();
  perform public.apply_returns_code_map();
  delete from public.purchase_xlsx_stage where true;
  return jsonb_build_object('stage', v_stage, 'mapped', v_mapped,
                            'conflict', v_conflict, 'applied', v_applied);
end$function$;

commit;
