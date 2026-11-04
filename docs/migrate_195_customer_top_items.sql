-- ═══════════════════════════════════════════════════════════════════
--  أكثر الأصناف طلبًا لكل عميل — كارت في شاشة العملاء
-- ═══════════════════════════════════════════════════════════════════
--  الترتيب **بعدد الفواتير** اللي اتطلب فيها الصنف (مش الكمية ولا
--  القيمة) بقرار المالك: ده اللي بيعبّر عن عادة العميل — دوا مزمن
--  بياخده كل شهر يسبق صنف اتاخد علبتين مرة واحدة.
--
--  **المرتجع مخصوم**: لو الصنف اترجّع كله في فاتورة، الفاتورة دي
--  ماتتحسبش «مرة». الربط بـ(رقم الفاتورة + كود الصنف) — returns_log
--  بيحمل رقم فاتورة البيع الأصلية.
--
--  ليه مفيش جدول محسوب: الاستعلام لعميل واحد بيخلص في **0.43 م.ث**
--  بالفهرس الموجود `idx_sales_items_cust`. جدول ليلي كان هيزوّد حاجة
--  تقدم وتحتاج مراقبة مقابل صفر مكسب.
--
--  ⚠️ مفيش فلتر فئات: اتفحصت تلات مصادر (jard_category_flags،
--  Item_Formats، Scientific_Groups) وكلهم بيغلطوا بشكل ظاهر — أقراص
--  متسجّلة «كريمات» و«أجهزة رياضية»، ومسكّن متسجّل «ADDICTION».
--  فلتر بيكذب أسوأ من مفيش فلتر.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.get_customer_top_items(
  p_cust_code text,
  p_limit     integer default 10,
  p_days      integer default null      -- null = كل الفترة
) returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_code text := nullif(btrim(coalesce(p_cust_code,'')), '');
  v_lim  int  := greatest(1, least(50, coalesce(p_limit, 10)));
  v_from date := case when p_days is null or p_days <= 0 then null
                      else (now() at time zone 'Africa/Cairo')::date - p_days end;
  v_out  jsonb;
begin
  if public.jwt_app_role() is null
     and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') <> 'service_role' then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  if v_code is null or v_code = '0' then
    return jsonb_build_object('rows','[]'::jsonb,'items',0,'bills',0);
  end if;

  with s as (
    /* سطر لكل (صنف، فاتورة) — الفاتورة الواحدة ممكن يتكرر فيها الصنف */
    select si.itm_code, si.bill_no,
           max(si.itm_name_ar) nm,
           sum(si.itm_qty)     qty,
           sum(si.line_total)  val,
           max(si.bill_date)   at
      from public.sales_items si
     where si.cust_code = v_code
       and (v_from is null or (si.bill_date at time zone 'Africa/Cairo')::date >= v_from)
     group by si.itm_code, si.bill_no
  ), r as (
    select rl.bill_no, rl.itm_code, sum(rl.back_qty) back
      from public.returns_log rl
     where rl.cust_code = v_code
     group by rl.bill_no, rl.itm_code
  ), j as (
    select s.*, coalesce(r.back, 0) back
      from s left join r on r.bill_no = s.bill_no and r.itm_code = s.itm_code
  ), g as (
    select itm_code,
           max(nm) nm,
           /* الفاتورة تتحسب «مرة» بس لو فضل منها كمية فعلًا */
           count(*) filter (where qty - back > 0.001)                      times,
           sum(greatest(qty - back, 0))                                    qty,
           sum(case when qty - back > 0.001 then val else 0 end)           val,
           max(at)                                                         last_at,
           sum(back)                                                       back
      from j group by itm_code
  )
  select jsonb_build_object(
    'items', (select count(*) from g where times > 0),
    'bills', (select count(distinct bill_no) from s),
    'rows',  coalesce((
      select jsonb_agg(x order by x.times desc, x.val desc)
        from (
          select itm_code, nm, times,
                 round(qty::numeric, 2)  qty,
                 round(val::numeric, 2)  val,
                 last_at,
                 ((now() at time zone 'Africa/Cairo')::date
                   - (last_at at time zone 'Africa/Cairo')::date) days_ago,
                 round(back::numeric, 2) returned
            from g
           where times > 0
           order by times desc, val desc
           limit v_lim) x), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $function$;

revoke all on function public.get_customer_top_items(text,integer,integer) from public;
grant execute on function public.get_customer_top_items(text,integer,integer) to authenticated, service_role;

notify pgrst, 'reload schema';
