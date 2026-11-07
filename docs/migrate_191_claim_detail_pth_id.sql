/* ═══════════════════════════════════════════════════════════════════
   تفاصيل المطالبة: ترجّع pth_id عشان زرار «عرض الفاتورة» يشتغل
   ═══════════════════════════════════════════════════════════════════
   شاشة التقفيل بقى فيها زرار بيفتح الفاتورة بأصنافها بنفس مودال
   «فواتير الشراء» (`get_purchase_invoice(branch, pth_id)`). في قائمة
   الفواتير المفتوحة الـ`pth_id` موجود أصلًا، لكن في **مودال مراجعة
   مطالبة مقفولة** كانت `get_claim_detail` بترجّع رقم فاتورة المورّد
   والتاريخ والقيمة بس — ومن غير `pth_id` مفيش طريقة نفتح بيها
   الفاتورة الصح (رقم المورّد مش مفتاح: بيتكرر بين الفروع).

   تعديل سطر واحد في الـaggregate، مفيش تغيير في أي قيمة معروضة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_claim_detail_impl(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare c record; v_out jsonb;
begin
  select * into c from supplier_claims where id=p_id;
  if not found then return jsonb_build_object('error','المطالبة غير موجودة'); end if;
  select jsonb_build_object(
    'id', c.id, 'branch', c.branch, 'vendor', c.ven_name_ar, 'closed_at', c.closed_at,
    'from_date', c.from_date, 'to_date', c.to_date,
    'invoices_total', c.invoices_total, 'returns_total', c.returns_total, 'notarr_total', c.notarr_total,
    'local_value', c.local_value, 'disc_pct', c.disc_pct, 'disc_value', c.disc_value,
    'disc_mode', coalesce(c.disc_mode,'local'),
    'net_paid', c.net_paid, 'note', c.note, 'closed_by', c.closed_by, 'is_baseline', c.is_baseline,
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('bill_no',h.ven_bill_no,'date',coalesce(h.sec_insert_date::date,h.ven_bill_date::date),'inv_date',h.ven_bill_date::date,'total',h.total_bill::numeric,'pth_id',h.pth_id) order by coalesce(h.sec_insert_date,h.ven_bill_date) desc),'[]'::jsonb)
                  from claim_invoices ci join purchase_invoices h on h.branch=ci.branch and h.pth_id=ci.pth_id where ci.claim_id=p_id),
    'returns', (
      select coalesce(jsonb_agg(x order by (x->>'date') desc),'[]'::jsonb) from (
        select jsonb_build_object('kind','على فاتورة','reason',cr.reason,'date',h.ven_bill_date::date,'bill_no',h.ven_bill_no,
          'code',coalesce(nullif(btrim(i.itm_code),''),i.itm_id::text),'name',coalesce(nullif(btrim(i.itm_name),''),'—'),
          'qty',i.itm_back_qty,'val',round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2)) x, h.ven_bill_date d
        from claim_returns cr
          join purchase_invoice_items i on i.branch=cr.branch and i.pth_id=cr.r1 and i.ptd_id=cr.r2
          join purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
        where cr.claim_id=p_id and cr.ret_kind='bill'
        union all
        select jsonb_build_object('kind','شراء عام','reason',cr.reason,'date',r.sec_insert_date::date,'bill_no',null,
          'code',coalesce(nullif(btrim(r.itm_code),''),r.itm_id::text),'name',coalesce(nullif(btrim(r.itm_name),''),'—'),
          'qty',r.qty,'val',round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2)) x, r.sec_insert_date d
        from claim_returns cr
          join purchase_returns r on r.branch=cr.branch and r.ibh_id=cr.r1 and r.ibd_id=cr.r2
        where cr.claim_id=p_id and cr.ret_kind='gen'
      ) s)
  ) into v_out;
  return v_out;
end$fn$;

notify pgrst, 'reload schema';
