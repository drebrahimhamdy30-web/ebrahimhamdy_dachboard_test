-- ٢٠٣: حارس خريطة أكواد المشتريات + تنظيف الربط المتعارض
--
-- الليه (اتكشف 2026-11-21): فاتورة فارما اوفر سيز 1020472635 على المعمورة
-- ظهرت في الشاشة باسم «لاميفين كريم» كود 5801، والصنف الحقيقي في eplus
-- هو «فوار فروت 5 مجم 6 كيس» كود `fr` من فاركو. الفاتورة والكمية والسعر
-- كلهم متزامنين صح — الغلط في ترجمة الرقم الداخلي للكود.
--
-- سببان:
-- ١) **استيراد الشيت كان بيرمي أي كود فيه حروف** (شرط /^\d+$/ في
--    purchase_invoices.html). عندنا ٣١٢ صنف بكود حروف في المخزون
--    (معمورة ١٠٥ · سان ٨٢ · بشر ٧١ · سيوف ٥٤) و**صفر** منهم في الخريطة.
--    فالرقم الداخلي 35235 مالقاش كوده `fr` واتطابق بكود رقمي غلط.
--    ده اتصلح في الواجهة مع الترحيل ده.
-- ٢) **البناء مافيهوش حارس للاتجاه التاني.** كان بيرفض الرقم الداخلي
--    اللي له أكتر من كود (`count(distinct code)=1`)، لكن مش بيرفض الكود
--    اللي اتنسب لأكتر من رقم داخلي في نفس الفرع — وده مستحيل يكون صح
--    لأن itm_id مستقل لكل فرع. النتيجة: ٩٤ كود على ١٩١ رقم داخلي،
--    وكلهم متسجّلين confidence=1 يعني «مؤكد».
--
-- الدرس: الخريطة قالت ثقة كاملة وهي غلط. من غير حارس، الربط الغلط بيعدّي
-- في صمت وبيلزق اسم ورصيد ومعدل صنف تاني على بند شراء.
--
-- وكمان: purchase_map_build (اللي الشاشة بتناديها) كان ناقصه فلتر الكود
-- الفاضي و`^0+$` اللي موجود في build_purchase_code_map — و`0` دي علامة
-- المالك وممنوع تتحط على أي صنف.

begin;

/* ═══ ١) الربط المتعارض يتسجّل بثقة صفر، والتطبيق يتجاهله ═══ */

create or replace function public.apply_item_code_map()
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer;
begin
  update public.purchase_invoice_items pi
     set itm_code = m.itm_code,
         itm_name = coalesce(m.itm_name, pi.itm_name)
  from public.item_code_map m
  where m.branch = pi.branch and m.itm_id = pi.itm_id
    and m.confidence >= 1          -- المشكوك مايتطبّقش
    and (pi.itm_code is distinct from m.itm_code
         or (m.itm_name is not null and pi.itm_name is distinct from m.itm_name));
  get diagnostics n = row_count;
  return n;
end$function$;

create or replace function public.apply_returns_code_map()
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer;
begin
  update public.purchase_returns r
     set itm_code = m.itm_code,
         itm_name = coalesce(m.itm_name, r.itm_name)
  from public.item_code_map m
  where m.branch = r.branch and m.itm_id = r.itm_id
    and m.confidence >= 1
    and (r.itm_code is distinct from m.itm_code
         or (m.itm_name is not null and r.itm_name is distinct from m.itm_name));
  get diagnostics n = row_count;
  return n;
end$function$;

/* ═══ ٢) البناء بحارس الاتجاهين ═══ */

create or replace function public.purchase_map_build()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
     /* الكود الفاضي و«0» مرفوضين — «0» علامة المالك وممنوع تتنسب لصنف */
     where coalesce(btrim(s.code), '') <> '' and btrim(s.code) !~ '^0+$'
  ),
  /* اتجاه ١: الرقم الداخلي لازم يكون له كود واحد */
  one_code as (
    select branch, itm_id from j group by branch, itm_id having count(distinct code) = 1
  ),
  picked as (
    select j.branch, j.itm_id, max(j.code) code, max(j.name) name
      from j join one_code o on o.branch = j.branch and o.itm_id = j.itm_id
     group by j.branch, j.itm_id
  ),
  /* اتجاه ٢ (الجديد): الكود لازم يكون لرقم داخلي واحد في الفرع.
     itm_id مستقل لكل فرع، فكود على رقمين = واحد منهم غلط قطعًا. */
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

  /* الربط المشكوك مايسيبش كود قديم غلط مطبّق على البنود */
  update public.purchase_invoice_items pi
     set itm_code = null, itm_name = null
    from public.item_code_map m
   where m.branch = pi.branch and m.itm_id = pi.itm_id and m.confidence = 0
     and pi.itm_code is not null;

  v_applied := public.apply_item_code_map();
  delete from public.purchase_xlsx_stage where true;
  return jsonb_build_object('stage', v_stage, 'mapped', v_mapped,
                            'conflict', v_conflict, 'applied', v_applied);
end$function$;

/* النسخة القديمة بنفس المنطق عشان ما يفضلش طريقين مختلفين للبناء */
create or replace function public.build_purchase_code_map()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  return public.purchase_map_build();
end$function$;

/* ═══ ٣) تقرير التعارض — للشاشة وللفحص ═══ */

create or replace function public.get_code_map_conflicts()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v jsonb;
begin
  perform require_app_role(array['admin','manager']);
  select coalesce(jsonb_agg(to_jsonb(r) order by r.branch, r.itm_code), '[]'::jsonb) into v
    from (
      select m.branch, m.itm_code,
             count(*) n_ids,
             string_agg(m.itm_id::text, ', ' order by m.itm_id) itm_ids,
             string_agg(distinct m.itm_name, ' | ') names,
             max(m.confidence) conf,
             (select count(*) from public.purchase_invoice_items pi
               where pi.branch = m.branch and pi.itm_id in (
                 select m2.itm_id from public.item_code_map m2
                  where m2.branch = m.branch and m2.itm_code = m.itm_code)) n_lines
        from public.item_code_map m
       group by m.branch, m.itm_code
      having count(*) > 1
    ) r;
  return v;
end$function$;

revoke all on function public.get_code_map_conflicts() from public, anon;
grant execute on function public.get_code_map_conflicts() to authenticated, service_role;

/* ═══ ٤) تنظيف الموجود ═══
   كل كود مربوط بأكتر من رقم داخلي في نفس الفرع: الربط بيتعلّم مشكوك،
   والبنود اللي اتكتب عليها الكود الغلط بترجع «غير مكوّدة».
   «مش عارف» أحسن من «غلط بثقة». الاستيراد الجاي هيعيد تكويدهم صح. */

update public.item_code_map m
   set confidence = 0, updated_at = now()
 where exists (
   select 1 from public.item_code_map m2
    where m2.branch = m.branch and m2.itm_code = m.itm_code and m2.itm_id <> m.itm_id);

update public.purchase_invoice_items pi
   set itm_code = null, itm_name = null
  from public.item_code_map m
 where m.branch = pi.branch and m.itm_id = pi.itm_id and m.confidence = 0
   and pi.itm_code is not null;

update public.purchase_returns r
   set itm_code = null, itm_name = null
  from public.item_code_map m
 where m.branch = r.branch and m.itm_id = r.itm_id and m.confidence = 0
   and r.itm_code is not null;

commit;
