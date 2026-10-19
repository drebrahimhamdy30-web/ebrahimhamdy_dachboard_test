/* ============================================================
   قاموس أكواد المشتريات: رفض الكود «صفر»
   ------------------------------------------------------------
   اتكشف وإحنا بنفحص القاموس بعد رفع مشتريات السنة (2026-10-19):

   فيه أصناف **مش مكوّدة في eplus** بيتصدّر لها الكود `0` في ملف
   «مشتريات تفصيلي»، وأسماؤها عشوائية زي ما الموظف كتبها
   (`c`, `be4`, `mo55`, `MO66`, `SR20`, `glt`, «فيونا قطن…»).
   الدالة كانت بتاخد الصفر على إنه كود حقيقي، فـ**١٧ صنف مختلف**
   اتسجّلوا بنفس الكود و**٣٧٥ بند** اتختموا بيه.

   الضرر: `search_item_cost` بيجمّع بالكود، فتكاليف منتجات لا علاقة
   لبعضها كانت بتتخلط تحت «صفر» وتطلع كأنها تاريخ سعر صنف واحد.
   وكمان `stock_flat` فيه كود `0` = «تحليل سكر»، فأي عرض بيربط
   الكود بالاسم كان بيوريك اسم غلط تمامًا.

   ⚠️ وقاعدة المالك صريحة: **`code='0'` علامته هو** — ممنوع أي
   أتمتة تحطها. المشكوك فيه يفضل فاضي.

   الإصلاح:
     ١) الدالة بترفض أي كود أصفار أو فاضي.
     ٢) مسح الـ١٧ مدخل الموجودين.
     ٣) تفريغ كود الـ٣٧٥ بند (الاسم بيفضل للتشخيص).

   البند الفاضي بيختفي من بحث التكلفة — وده **الصح**: الصنف فعلًا
   مش مكوّد عند المصدر، و«مش موجود» أأمن من خلط تكاليف.
   ============================================================ */
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
       and (s.exp_date is null or pi.exp_date is null or s.exp_date = pi.exp_date)
     /* ⚠️ الصفر مش كود — صنف مش مكوّد في eplus. ياخد فاضي. */
     where coalesce(btrim(s.code), '') <> '' and btrim(s.code) !~ '^0+$'
  ),
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

/* تنظيف اللي اتسجّل غلط */
update public.purchase_invoice_items
   set itm_code = null
 where itm_code ~ '^0+$';

delete from public.item_code_map
 where itm_code is null or btrim(itm_code) = '' or btrim(itm_code) ~ '^0+$';

/* فهرس للجدول المؤقت — الدالة بتعمل join عليه بـ(branch, pth_id)
   و١٣٠ ألف سطر من غير فهرس كانت بتوصل المهلة */
create index if not exists idx_pxs_branch_pth on public.purchase_xlsx_stage (branch, pth_id);
