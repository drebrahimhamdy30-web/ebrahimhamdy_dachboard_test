/* ═══════════════════════════════════════════════════════════════════
   فرق تصحيح رصيد المورّد — vendor_balance_adjust
   ═══════════════════════════════════════════════════════════════════
   eplus عنده فرق ثابت لبعض الموردين بين كشف الحساب (دفتر الأستاذ) والحقل
   المخزّن ven_current_credit (مثال تارجت: مخزّن 33,075 / كشف 35,046 = فرق 1,971.61).
   الفرق ثابت (كل حركة بتأثّر على الاتنين بنفس القيمة)، فبنخزّن «فرق تصحيح»
   لكل (فرع، مورّد) ونعرض: الرصيد = ven_current_credit + adjust = يطابق كشف الحساب.

   set_vendor_balance_target(branch, ven, target) بيحسب الفرق = الهدف − المخزّن الحالي.
   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.vendor_balance_adjust (
  branch      text not null,
  ven_name_ar text not null,
  ven_code    text,
  adjust      numeric not null default 0,   -- (كشف الحساب − المخزّن)
  note        text,
  updated_by  text,
  updated_at  timestamptz default now(),
  primary key (branch, ven_name_ar)
);
alter table public.vendor_balance_adjust enable row level security;
grant all on public.vendor_balance_adjust to service_role;
grant select on public.vendor_balance_adjust to anon, authenticated;
drop policy if exists p_read on public.vendor_balance_adjust;
create policy p_read on public.vendor_balance_adjust for select to anon, authenticated using (true);

/* ضبط الفرق من رصيد eplus المستهدف (كشف الحساب) */
create or replace function public.set_vendor_balance_target(p_branch text, p_vendor text, p_target numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_stored numeric; v_adj numeric; v_by text;
begin
  perform public.require_page_edit('supplier_claims');
  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'full_name', public.jwt_app_role(), 'نظام');
  select max(ven_current_credit) into v_stored from purchase_vendors where branch=p_branch and ven_name_ar=p_vendor;
  v_stored := coalesce(v_stored,0);
  v_adj := round((p_target - v_stored)::numeric, 2);
  insert into vendor_balance_adjust(branch, ven_name_ar, adjust, note, updated_by)
  values (p_branch, p_vendor, v_adj, 'target='||p_target, v_by)
  on conflict (branch, ven_name_ar) do update set adjust=excluded.adjust, note=excluded.note, updated_by=excluded.updated_by, updated_at=now();
  return jsonb_build_object('stored', v_stored, 'target', p_target, 'adjust', v_adj);
end$fn$;
grant execute on function public.set_vendor_balance_target(text,text,numeric) to authenticated;

/* get_supplier_open — الرصيد بقى = المخزّن + الفرق */
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
    select h.pth_id, h.ven_bill_no, h.ven_bill_date::date d, h.total_bill::numeric total
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

/* تطبيق الفروق بالجملة من شيت أرصدة eplus (branch, code, bal) — ضبط كامل */
create or replace function public.apply_vendor_adjust_bulk(p_rows jsonb, p_thresh numeric default 0.5)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare n int; matched int;
begin
  delete from vendor_balance_adjust where true;
  with e as (select * from jsonb_to_recordset(p_rows) as t(branch text, code text, bal numeric)),
  ins as (
    insert into vendor_balance_adjust(branch, ven_name_ar, ven_code, adjust, note, updated_by)
    select e.branch, pv.ven_name_ar, pv.ven_code, round((e.bal - pv.ven_current_credit)::numeric,2), 'eplus xlsx', 'نظام'
      from e join purchase_vendors pv on pv.branch=e.branch and pv.ven_code::text=e.code
     where abs(e.bal - coalesce(pv.ven_current_credit,0)) > p_thresh
    returning 1)
  select (select count(*) from ins) into n;
  select count(*) into matched from (select * from jsonb_to_recordset(p_rows) as t(branch text, code text, bal numeric)) q
    join purchase_vendors pv on pv.branch=q.branch and pv.ven_code::text=q.code;
  return jsonb_build_object('adjusted', n, 'matched', matched);
end$fn$;
grant execute on function public.apply_vendor_adjust_bulk(jsonb,numeric) to service_role, authenticated;

notify pgrst, 'reload schema';
