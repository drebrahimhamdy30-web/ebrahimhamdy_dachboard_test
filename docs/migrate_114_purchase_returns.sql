/* ═══════════════════════════════════════════════════════════════════
   مرتجعات الشراء — جدول + مزامنة + تقرير مدمج
   ═══════════════════════════════════════════════════════════════════
   فيه نوعين من مرتجعات الموردين في eplus:
     1) «مرتجع على فاتورة» = pur_trans_d.itm_back_qty (مدمج في الفاتورة) — متزامن أصلًا
        في purchase_invoice_items.
     2) «مرتجع شراء عام» = جدول مستقل Item_back_h/d (مستند مرتجع، مش مربوط بفاتورة
        غالبًا ibh_pur_id=0) — **مش متزامن** → نزامنه هنا في purchase_returns.

   itm_id الداخلي بيترجم لكودنا بنفس قاموس item_code_map (branch, itm_id → code+name)
   عبر apply_returns_code_map (post_rpc لمهمة المزامنة الجديدة).

   get_purchase_returns بيدمج النوعين مع عمود «المصدر» + تاريخ المرتجع وتاريخ الفاتورة.
   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.purchase_returns (
  branch          text        not null,
  ibh_id          bigint      not null,   -- رأس المرتجع
  ibd_id          bigint      not null,   -- بند المرتجع
  ven_id          bigint,
  ven_code        text,
  ven_name_ar     text,
  ibh_total_value numeric,                -- قيمة المستند (رأس)
  ibh_back_reason integer,
  ibh_type        integer,
  ibh_pur_id      bigint,                 -- ربط بفاتورة شراء (0 = عام)
  sec_insert_date timestamp,              -- تاريخ المرتجع (قاهرة حرفي)
  sec_update_date timestamp,
  sec_insert_uid  text,
  ibh_sto_id      bigint,
  itm_id          bigint,
  qty             numeric,
  ibd_ven_price   numeric,                -- سعر المورّد للمرتجع
  ibd_pharm_price numeric,
  ibd_exp_date    timestamp,
  ibd_c_id        bigint,
  itm_code        text,                   -- كودنا (من القاموس)
  itm_name        text,                   -- اسمنا (من القاموس)
  synced_at       timestamptz default now(),
  primary key (branch, ibh_id, ibd_id)
);
create index if not exists ix_purchase_returns_date on public.purchase_returns (sec_insert_date);
create index if not exists ix_purchase_returns_ven  on public.purchase_returns (ven_name_ar);
create index if not exists ix_purchase_returns_code on public.purchase_returns (itm_code);

alter table public.purchase_returns enable row level security;
grant all on public.purchase_returns to service_role;   -- المزامنة تكتب بالخدمة (تتخطى RLS)
-- القراءة عبر RPC (security definer) فمش محتاجين grant لـanon على الجدول.

/* ترجمة الكود/الاسم من القاموس — post_rpc للمزامنة */
create or replace function public.apply_returns_code_map()
returns integer language plpgsql security definer set search_path to 'public' as $fn$
declare n integer;
begin
  update public.purchase_returns r
     set itm_code = m.itm_code,
         itm_name = coalesce(m.itm_name, r.itm_name)
  from public.item_code_map m
  where m.branch = r.branch and m.itm_id = r.itm_id
    and (r.itm_code is distinct from m.itm_code
         or (m.itm_name is not null and r.itm_name is distinct from m.itm_name));
  get diagnostics n = row_count;
  return n;
end$fn$;
grant execute on function public.apply_returns_code_map() to service_role, authenticated;

/* تقرير مرتجعات الشراء المدمج (النوعين) — تقرير عرض لحظي */
create or replace function public.get_purchase_returns(
  p_branch text default null,
  p_vendor text default null,
  p_from   date default null,
  p_to     date default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_out jsonb;
begin
  with gen as (
    select 'مرتجع شراء عام'::text source,
           r.sec_insert_date::date ret_date,
           pb.ven_bill_date::date  bill_date,
           pb.ven_bill_no          bill_no,
           r.branch,
           coalesce(r.ven_name_ar,'—') vendor,
           coalesce(nullif(btrim(r.itm_code),''), r.itm_id::text) code,
           coalesce(nullif(btrim(r.itm_name),''), '—') name,
           r.qty,
           r.ibd_ven_price price,
           round((r.qty * coalesce(r.ibd_ven_price,0))::numeric,2) value
      from public.purchase_returns r
      left join public.purchase_invoices pb
        on nullif(r.ibh_pur_id,0) is not null and pb.branch=r.branch and pb.pth_id=r.ibh_pur_id
     where (p_branch is null or r.branch = p_branch)
       and (p_vendor is null or r.ven_name_ar ilike '%'||p_vendor||'%')
       and (p_from is null or r.sec_insert_date::date >= p_from)
       and (p_to   is null or r.sec_insert_date::date <= p_to)
  ),
  inv as (
    select 'مرتجع على فاتورة'::text source,
           h.ven_bill_date::date ret_date,
           h.ven_bill_date::date bill_date,
           h.ven_bill_no         bill_no,
           i.branch,
           coalesce(h.ven_name_ar,'—') vendor,
           coalesce(nullif(btrim(i.itm_code),''), i.itm_id::text) code,
           coalesce(nullif(btrim(i.itm_name),''), '—') name,
           i.itm_back_qty qty,
           i.itm_back_pharm price,
           round((i.itm_back_qty * coalesce(i.itm_back_pharm,0))::numeric,2) value
      from public.purchase_invoice_items i
      join public.purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
     where coalesce(i.itm_back_qty,0) <> 0
       and (p_branch is null or i.branch = p_branch)
       and (p_vendor is null or h.ven_name_ar ilike '%'||p_vendor||'%')
       and (p_from is null or h.ven_bill_date::date >= p_from)
       and (p_to   is null or h.ven_bill_date::date <= p_to)
  ),
  u as (select * from gen union all select * from inv)
  select coalesce(jsonb_agg(to_jsonb(t) order by t.ret_date desc nulls last, t.value desc nulls last), '[]'::jsonb)
    into v_out from u t;
  return v_out;
end$fn$;
grant execute on function public.get_purchase_returns(text,text,date,date) to anon, authenticated;

notify pgrst, 'reload schema';
