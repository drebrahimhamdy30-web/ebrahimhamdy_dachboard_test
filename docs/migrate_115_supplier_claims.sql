/* ═══════════════════════════════════════════════════════════════════
   تقفيل مطالبات الموردين — طبقة تسوية فوق بيانات eplus (قراءة فقط)
   ═══════════════════════════════════════════════════════════════════
   eplus مابيسجّلش الدفع على الفاتورة (pth_paid=0)؛ الدفع على الحساب
   والرصيد الحقيقي = purchase_vendors.ven_current_credit. فبنبني طبقة
   تسوية عندنا: المالك يعلّم فواتير + مرتجعات «مقفولة» حتى يتطابق
   «الصافي المفتوح» مع رصيد eplus. **مفيش أي كتابة في eplus.**

   - supplier_claims: المطالبة (المبلغ/الخصم/الصافي/مين أقفل).
   - claim_invoices / claim_returns: أي فاتورة/مرتجع اتقفل (مرة واحدة).
   - المرتجعات نوعين: 'bill' (مرتجع على فاتورة = itm_back على البند) و
     'gen' (مرتجع شراء عام = purchase_returns). سبب المرتجع يُخزَّن.
   - خط البداية: كل الفواتير/المرتجعات قبل 2026-09-01 تتعلّم مقفولة
     (مطالبة أساس is_baseline) عشان نبدأ من 1-9-2026.
   - الصلاحية: require_page_edit('supplier_claims') — من شاشة الصلاحيات.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.supplier_claims (
  id             bigserial primary key,
  branch         text not null,
  ven_name_ar    text not null,
  closed_at      timestamptz not null default now(),
  from_date      date,
  to_date        date,
  invoices_total numeric default 0,
  returns_total  numeric default 0,   -- مرتجع (غير مطلوب/تالف)
  notarr_total   numeric default 0,   -- لم يصل
  local_value    numeric default 0,
  disc_pct       numeric default 0,
  disc_value     numeric default 0,
  net_paid       numeric default 0,
  note           text,
  closed_by      text,
  is_baseline    boolean default false
);
create index if not exists ix_claims_ven on public.supplier_claims (branch, ven_name_ar, closed_at);

create table if not exists public.claim_invoices (
  branch    text not null,
  pth_id    bigint not null,
  claim_id  bigint references public.supplier_claims(id) on delete cascade,
  closed_at timestamptz default now(),
  primary key (branch, pth_id)
);

create table if not exists public.claim_returns (
  branch    text not null,
  ret_kind  text not null,          -- 'bill' | 'gen'
  r1        bigint not null,         -- pth_id (bill) | ibh_id (gen)
  r2        bigint not null,         -- ptd_id (bill) | ibd_id (gen)
  reason    text,                    -- سبب المرتجع
  claim_id  bigint references public.supplier_claims(id) on delete cascade,
  closed_at timestamptz default now(),
  primary key (branch, ret_kind, r1, r2)
);

alter table public.supplier_claims enable row level security;
alter table public.claim_invoices  enable row level security;
alter table public.claim_returns   enable row level security;
grant all on public.supplier_claims, public.claim_invoices, public.claim_returns to service_role;
grant usage, select on sequence public.supplier_claims_id_seq to service_role, authenticated;

/* ── القائمة المفتوحة + المطابقة لمورّد ──────────────────────────────
   بترجّع: رصيد eplus + إجماليات كل المفتوح (للمطابقة، بلا تاريخ) +
   قوائم الفواتير والمرتجعات المفتوحة في الفترة المعروضة. */
create or replace function public.get_supplier_open(
  p_branch text,
  p_vendor text,
  p_from   date default null,
  p_to     date default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_out jsonb;
begin
  if p_vendor is null or p_branch is null then
    return jsonb_build_object('error','لازم تختار المورّد والفرع');
  end if;

  with
  bal as (
    select max(ven_current_credit) c from purchase_vendors
     where branch=p_branch and ven_name_ar=p_vendor
  ),
  /* فواتير مفتوحة (مش في claim_invoices) */
  inv_open as (
    select h.pth_id, h.ven_bill_no, h.ven_bill_date::date d, h.total_bill::numeric total
      from purchase_invoices h
     where h.branch=p_branch and h.ven_name_ar=p_vendor
       and not exists (select 1 from claim_invoices c where c.branch=h.branch and c.pth_id=h.pth_id)
  ),
  /* مرتجع على فاتورة مفتوح */
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
  /* مرتجع شراء عام مفتوح */
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

/* ── إغلاق مطالبة (محميّة بصلاحية الشاشة) ───────────────────────────
   p_inv = [pth_id,...] ؛ p_ret = [{kind,r1,r2,reason},...]
   الإجماليات تُحسب في السيرفر من القيم الحقيقية (مش من العميل). */
create or replace function public.close_supplier_claim(
  p_branch text, p_vendor text,
  p_inv jsonb, p_ret jsonb,
  p_local numeric default 0, p_pct numeric default 0,
  p_note text default null, p_from date default null, p_to date default null
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

  /* إجمالي الفواتير = مجموع total_bill للفواتير المحدّدة */
  select coalesce(sum(h.total_bill),0) into v_inv
    from purchase_invoices h
   where h.branch=p_branch and h.ven_name_ar=p_vendor
     and h.pth_id in (select (jsonb_array_elements_text(coalesce(p_inv,'[]'::jsonb)))::bigint);

  /* إجمالي المرتجعات مقسّم بالسبب (لم يصل منفصل) — من القيم الحقيقية */
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
  select p_branch, r->>'kind', (r->>'r1')::bigint, (r->>'r2')::bigint, coalesce(r->>'reason','غير مطلوب'), v_id
  from jsonb_array_elements(coalesce(p_ret,'[]'::jsonb)) r
  on conflict (branch, ret_kind, r1, r2) do nothing;

  return jsonb_build_object('id', v_id, 'net', v_net, 'invoices', v_inv, 'returns', v_ret, 'notarr', v_notarr, 'disc', v_disc, 'by', v_by);
end$fn$;
grant execute on function public.close_supplier_claim(text,text,jsonb,jsonb,numeric,numeric,text,date,date) to authenticated;

/* ── سجل المطالبات + إلغاء إغلاق ────────────────────────────────── */
create or replace function public.get_supplier_claims(p_branch text default null, p_vendor text default null)
returns setof public.supplier_claims language sql stable security definer set search_path to 'public' as $$
  select * from public.supplier_claims
   where (p_branch is null or branch=p_branch) and (p_vendor is null or ven_name_ar=p_vendor)
   order by closed_at desc
$$;
grant execute on function public.get_supplier_claims(text,text) to anon, authenticated;

create or replace function public.reopen_supplier_claim(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare n integer;
begin
  perform public.require_page_edit('supplier_claims');
  delete from supplier_claims where id=p_id and coalesce(is_baseline,false)=false;  -- cascade يشيل البنود
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n>0);
end$fn$;
grant execute on function public.reopen_supplier_claim(bigint) to authenticated;

notify pgrst, 'reload schema';
