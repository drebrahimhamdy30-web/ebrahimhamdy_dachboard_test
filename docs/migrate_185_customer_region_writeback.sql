-- migrate_185_customer_region_writeback.sql
-- شاشة «تعيين مناطق العملاء»: لقطة مناطق eplus + طابور الكتابة.
-- القائمة المنسدلة فى الشاشة بتقرا من eplus_delivery_regions (لقطة من
-- Delivery_cost_region على الماستر، بيحدّثها scripts/region_writeback.ps1).
-- الموظف يختار منطقة ويحفظ → صف فى customer_region_queue → السكربت على
-- الماستر يطبّقه على eplus (Customer_Delivery.cd_region_id).
--
-- مُطبّق على السحابة (rxtjoqulmgkkcohmgzgi) 2026-10-31 عبر MCP.
-- للقاعدة الذاتية (supabase.ebrahimhamdy.com): طبّقه بـpsql لو الشاشة هتُستخدم هناك.

create table if not exists public.eplus_delivery_regions(
  dc_id         int primary key,
  name          text not null,
  delivery_cost numeric,
  synced_at     timestamptz not null default now()
);
alter table public.eplus_delivery_regions enable row level security;
grant select on public.eplus_delivery_regions to authenticated;
drop policy if exists edr_sel on public.eplus_delivery_regions;
create policy edr_sel on public.eplus_delivery_regions for select to authenticated using (true);

create table if not exists public.customer_region_queue(
  id           bigint generated always as identity primary key,
  cust_code    text not null,
  cust_address text,
  region_name  text not null,
  dc_id        int,
  branch_id    uuid,
  requested_by text,
  status       text not null default 'pending',   -- pending | done | failed | skipped
  result_note  text,
  created_at   timestamptz not null default now(),
  applied_at   timestamptz
);
alter table public.customer_region_queue enable row level security;
grant select, insert on public.customer_region_queue to authenticated;
drop policy if exists crq_sel on public.customer_region_queue;
drop policy if exists crq_ins on public.customer_region_queue;
create policy crq_sel on public.customer_region_queue for select to authenticated using (true);
create policy crq_ins on public.customer_region_queue for insert to authenticated with check (true);

create index if not exists crq_pending_idx on public.customer_region_queue(created_at) where status='pending';
create index if not exists crq_cust_idx on public.customer_region_queue(cust_code, cust_address);
create unique index if not exists crq_uniq_pending
  on public.customer_region_queue(cust_code, coalesce(cust_address,'')) where status='pending';
