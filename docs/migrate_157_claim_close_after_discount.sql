/* ═══════════════════════════════════════════════════════════════════
   تقفيل المطالبة يسجّل قيمة الفواتير **بعد الخصم**
   ═══════════════════════════════════════════════════════════════════
   ── اللي كان بيحصل ──────────────────────────────────────────────
   `migrate_148` خلّى **العرض** بعد الخصم (`total_bill - total_des_mon`)
   عشان يطابق كشف المورّد. لكن `close_supplier_claim_impl` فضلت
   بتسجّل `total_bill` لوحده = **قبل** الخصم.

   النتيجة: الرقم اللي بيتخزّن في `supplier_claims.invoices_total`
   أعلى من اللي على الشاشة وأعلى من كشف المورّد. على مطالبة فارما
   اوفر سيز — سيدى بشر (18.09–17.10.2026) كان هيتسجّل
   **123,740.70** بدل **122,971.02** — فرق **769.68** جنيه،
   و`net_paid` غلط بنفس القيمة. ومحصلة كل مطالبة مقفولة قبل كده
   فيها نفس الإزاحة.

   ── التغيير ─────────────────────────────────────────────────────
   سطر واحد: `sum(total_bill)` بقى `sum(total_bill - coalesce(total_des_mon,0))`
   عشان يبقى نفس تعريف `inv_open.total` في `get_supplier_open`.

   ⚠️ المرتجعات والخصم النقدي والصافي مالهمش تغيير — دول محسوبين
      صح من الأصل.

   ── المطالبات المقفولة قبل كده ───────────────────────────────────
   ماتصلّحتش أثريًا بقصد: `reopen_supplier_claim(id)` بيفك المطالبة
   وتتقفل تاني بالرقم الصح. التصحيح الجماعي كان هيعدّل أرقام
   مدفوعات اتسوّت فعلًا مع الموردين.

   ── أول استخدام ─────────────────────────────────────────────────
   المطالبة رقم **68** (فارما اوفر سيز · سيدى بشر) اتقفلت بعد الإصلاح:
   فواتير 122,971.02 · مرتجعات 3,114.26 · خصم 5.9% = 2,856.07 ·
   المدفوع **117,000.69**.

   ملحوظة: الدالة كانت متطبّقة على السحابة بـ`create or replace`
   مباشر من غير ملف في 2026-10-21 — الملف ده هو توثيقها، وبيتطبّق
   على **السيرفر الذاتي** لأول مرة.

   ⚠️ `create or replace` لازم يعيد كتابة الـ`default`s في التوقيع،
      وإلا بيرجّع `42P13 cannot remove parameter defaults`.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.close_supplier_claim_impl(
  p_branch text, p_vendor text, p_inv jsonb, p_ret jsonb,
  p_local numeric default 0, p_pct numeric default 0, p_note text default null,
  p_from date default null, p_to date default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_by text; v_id bigint;
  v_inv numeric := 0; v_ret numeric := 0; v_notarr numeric := 0; v_disc numeric; v_net numeric;
  r jsonb;
begin
  perform public.require_page_edit('supplier_claims');
  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'full_name',
                   nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'name',
                   public.jwt_app_role(), 'غير معروف');
  /* بعد الخصم — زي ما الشاشة بتعرض (migrate_148) وزي ما كشف
     المورّد بيحاسب. total_bill لوحده كان بيسجّل في المطالبة رقم
     أعلى من اللي على الشاشة وأعلى من كشف المورّد. */
  select coalesce(sum(h.total_bill - coalesce(h.total_des_mon,0)),0) into v_inv
    from purchase_invoices h
   where h.branch=p_branch and h.ven_name_ar=p_vendor
     and h.pth_id in (select (jsonb_array_elements_text(coalesce(p_inv,'[]'::jsonb)))::bigint);
  for r in select * from jsonb_array_elements(coalesce(p_ret,'[]'::jsonb)) loop
    declare v numeric := 0; k text := r->>'kind'; reason text := coalesce(r->>'reason','غير مطلوب');
    begin
      if k='bill' then
        select round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2) into v
          from purchase_invoice_items i where i.branch=p_branch and i.pth_id=(r->>'r1')::bigint and i.ptd_id=(r->>'r2')::bigint;
      else
        select round((x.qty*coalesce(x.ibd_ven_price,0))::numeric,2) into v
          from purchase_returns x where x.branch=p_branch and x.ibh_id=(r->>'r1')::bigint and x.ibd_id=(r->>'r2')::bigint;
      end if;
      v := coalesce(v,0);
      if reason='لم يصل' then v_notarr := v_notarr + v; else v_ret := v_ret + v; end if;
    end;
  end loop;
  v_disc := round(coalesce(p_local,0)*coalesce(p_pct,0)/100.0, 2);
  v_net  := v_inv - v_ret - v_notarr - v_disc;
  insert into supplier_claims(branch, ven_name_ar, from_date, to_date, invoices_total, returns_total,
    notarr_total, local_value, disc_pct, disc_value, net_paid, note, closed_by)
  values (p_branch, p_vendor, p_from, p_to, v_inv, v_ret, v_notarr, coalesce(p_local,0),
          coalesce(p_pct,0), v_disc, v_net, p_note, v_by)
  returning id into v_id;
  insert into claim_invoices(branch, pth_id, claim_id)
  select p_branch, (jsonb_array_elements_text(coalesce(p_inv,'[]'::jsonb)))::bigint, v_id
  on conflict (branch, pth_id) do nothing;
  insert into claim_returns(branch, ret_kind, r1, r2, reason, claim_id)
  select p_branch, el->>'kind', (el->>'r1')::bigint, (el->>'r2')::bigint, coalesce(el->>'reason','غير مطلوب'), v_id
  from jsonb_array_elements(coalesce(p_ret,'[]'::jsonb)) el
  on conflict (branch, ret_kind, r1, r2) do nothing;
  return jsonb_build_object('id', v_id, 'net', v_net, 'invoices', v_inv, 'returns', v_ret, 'notarr', v_notarr, 'disc', v_disc, 'by', v_by);
end$fn$;

notify pgrst, 'reload schema';
