/* ═══════════════════════════════════════════════════════════════════
   قيمة فاتورة المورّد بعد الخصم — عشان تطابق كشف حساب المورّد
   ═══════════════════════════════════════════════════════════════════
   ── الملاحظة (المالك) ───────────────────────────────────────────
   كشف حساب فارما اوفر سيز للمعمورة مش مطابق لشاشة تقفيل المطالبات.

   ── اللي اتكشف بالفحص ───────────────────────────────────────────
   الفواتير **كلها موجودة وصح**، وحاجتين مختلفتين بس:

   1) **الرقم**: فيه تلات سلاسل أرقام لنفس الفاتورة —
        • عندنا `ven_bill_no` = 1018455086 (اللي الصيدلية بتكتبه من
          الإذن اللي بيجي مع البضاعة)
        • كشف المورّد «رقم المستند» = 9145662204
        • كشف المورّد «رقم إذن الاستلام» = 8822707315
      فالبحث برقم الكشف عمره ما هيلاقي حاجة. (مش موضوع الترحيل ده —
      مجرد توثيق، الحل المقترح بحث بالقيمة.)

   2) **القيمة**: الشاشة كانت بتعرض `total_bill` = **قبل** الخصم،
      والمورّد بيحاسب **بعد** الخصم. والمطابقة بالقيمة بعد الخصم
      طلعت مظبوطة بالقرش على ٨ فواتير متتالية:

        13.10  110.5 · 1390.6 · 1276
        14.10  493.5 · 3341.6 · 1543.5 · 4400 · 290.4

      وعلى فترة الكشف (17 سبتمبر–16 أكتوبر) في المعمورة: 109 فاتورة،
      **87 منها عليها خصم**، والفرق الكلي 1,595.09 جنيه كان بيبان
      كأنه اختلاف وهو مش اختلاف.

   ── التغيير ─────────────────────────────────────────────────────
   `inv_open.total` بقى `total_bill - total_des_mon`. وده بيغيّر
   القيمة المعروضة لكل فاتورة **و** `open_inv_total` اللي بيتقارن
   بالرصيد — وده المقصود: المستحق للمورّد هو الرقم بعد الخصم.

   ⚠️ ماغيّرتش حاجة في حساب الرصيد نفسه (`ven_current_credit`) ولا في
      المرتجعات — دول من eplus زي ما هم.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_supplier_open(
  p_branch text, p_vendor text, p_from date default null, p_to date default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_out jsonb;
begin
  if p_vendor is null or p_branch is null then
    return jsonb_build_object('error','لازم تختار المورّد والفرع');
  end if;
  with
  bal as (
    select coalesce(max(ven_current_credit),0)
         + coalesce((select adjust from vendor_balance_adjust a where a.branch=p_branch and a.ven_name_ar=p_vendor),0) c
    from purchase_vendors where branch=p_branch and ven_name_ar=p_vendor
  ),
  inv_open as (
    /* بعد الخصم — ده الرقم اللي المورّد بيحاسب بيه وبيظهر في كشفه.
       total_bill لوحده (قبل الخصم) كان بيخلّي كل فاتورة عليها خصم
       تبان مختلفة عن الكشف وهي مطابقة. */
    select h.pth_id, h.ven_bill_no, h.ven_bill_date::date d,
           (h.total_bill - coalesce(h.total_des_mon,0))::numeric total
      from purchase_invoices h
     where h.branch=p_branch and h.ven_name_ar=p_vendor
       and not exists (select 1 from claim_invoices c where c.branch=h.branch and c.pth_id=h.pth_id)
  ),
  ret_bill_open as (
    select i.pth_id r1, i.ptd_id r2, h.ven_bill_date::date d, h.ven_bill_no bill_no,
           coalesce(nullif(btrim(i.itm_code),''), i.itm_id::text) code,
           coalesce(nullif(btrim(i.itm_name),''),'—') name,
           i.itm_back_qty qty, coalesce(i.itm_back_pharm,i.itm_pur_price) price,
           round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2) val
      from purchase_invoice_items i
      join purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
     where i.branch=p_branch and h.ven_name_ar=p_vendor and coalesce(i.itm_back_qty,0)<>0
       and not exists (select 1 from claim_returns c where c.branch=i.branch and c.ret_kind='bill' and c.r1=i.pth_id and c.r2=i.ptd_id)
  ),
  ret_gen_open as (
    select r.ibh_id r1, r.ibd_id r2, r.sec_insert_date::date d, null::text bill_no,
           coalesce(nullif(btrim(r.itm_code),''), r.itm_id::text) code,
           coalesce(nullif(btrim(r.itm_name),''),'—') name,
           r.qty, r.ibd_ven_price price,
           round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2) val
      from purchase_returns r
     where r.branch=p_branch and r.ven_name_ar=p_vendor
       and not exists (select 1 from claim_returns c where c.branch=r.branch and c.ret_kind='gen' and c.r1=r.ibh_id and c.r2=r.ibd_id)
  )
  select jsonb_build_object(
    'balance', (select c from bal),
    'open_inv_total', (select coalesce(sum(total),0) from inv_open),
    'open_ret_total', (select coalesce(sum(val),0) from ret_bill_open) + (select coalesce(sum(val),0) from ret_gen_open),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('pth_id',pth_id,'bill_no',ven_bill_no,'date',d,'total',total) order by d desc),'[]'::jsonb)
                   from inv_open where (p_from is null or d>=p_from) and (p_to is null or d<=p_to)),
    'returns', (
      select coalesce(jsonb_agg(x order by (x->>'date') desc),'[]'::jsonb) from (
        select jsonb_build_object('kind','bill','r1',r1,'r2',r2,'date',d,'bill_no',bill_no,'code',code,'name',name,'qty',qty,'price',price,'val',val) x, d
          from ret_bill_open where (p_from is null or d>=p_from) and (p_to is null or d<=p_to)
        union all
        select jsonb_build_object('kind','gen','r1',r1,'r2',r2,'date',d,'bill_no',bill_no,'code',code,'name',name,'qty',qty,'price',price,'val',val) x, d
          from ret_gen_open where (p_from is null or d>=p_from) and (p_to is null or d<=p_to)
      ) s)
  ) into v_out;
  return v_out;
end$fn$;
grant execute on function public.get_supplier_open(text,text,date,date) to anon, authenticated;

notify pgrst, 'reload schema';
