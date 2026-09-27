-- ═══════════════════════════════════════════════════════════════════
-- مراجعة الأسعار: إظهار العميل (اسمه وكوده)
-- ═══════════════════════════════════════════════════════════════════
-- المراجع بيشوف مخالفة السعر ومش عارف اتباعت لمين — والعميل مهم عشان
-- يعرف لو ده خصم لعميل بعينه ولا غلط إدخال. الدالة كانت بترجّع cust_name
-- من غير الكود، والشاشة مكانتش بتعرض أي منهم.
-- بقت ترجّع cust_code كمان، والشاشة بتعرض عمود «العميل» = الاسم + الكود.
-- (تغيير أعمدة الخرج بيستلزم DROP ثم CREATE — جوّه ترانزاكشن واحدة.)
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.sales_price_review(timestamptz, timestamptz, text);

CREATE FUNCTION public.sales_price_review(
  p_from timestamptz DEFAULT NULL,
  p_to   timestamptz DEFAULT NULL,
  p_store text DEFAULT NULL)
RETURNS TABLE(id bigint, bill_no text, bill_date timestamptz, store_name text, employee_name text,
              cust_code text, cust_name text, itm_code text, itm_name_ar text, unit_name text,
              unit_kind text, unit_price numeric, stock_unit_price numeric, price_diff numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
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

GRANT EXECUTE ON FUNCTION public.sales_price_review(timestamptz,timestamptz,text) TO anon, authenticated;

COMMIT;
