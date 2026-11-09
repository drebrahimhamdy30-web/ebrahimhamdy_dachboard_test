-- migrate_198_customer_region_edit.sql
-- تعديل منطقة عميل موجودة (بحث بالكود): طلب جلب عناوين العميل من eplus +
-- جدول نتيجة العناوين بمناطقها الحالية + عمود allow_overwrite للكتابة فوق الموجود.
-- مُطبّق على السحابة 2026-11-09. سكربت الماستر region_writeback.ps1 بيعالج الجلب
-- (قسم التطبيق) ويحترم allow_overwrite.

create table if not exists public.customer_address_lookups(
  id          bigint generated always as identity primary key,
  cust_code   text not null,
  status      text not null default 'pending',  -- pending|done|notfound|failed
  requested_by text,
  created_at  timestamptz not null default now(),
  done_at     timestamptz
);
alter table public.customer_address_lookups enable row level security;
grant select, insert on public.customer_address_lookups to authenticated;
grant all on public.customer_address_lookups to service_role;
drop policy if exists cal_sel on public.customer_address_lookups;
drop policy if exists cal_ins on public.customer_address_lookups;
create policy cal_sel on public.customer_address_lookups for select to authenticated using (true);
create policy cal_ins on public.customer_address_lookups for insert to authenticated with check (true);
create index if not exists cal_pending_idx on public.customer_address_lookups(created_at) where status='pending';

create table if not exists public.customer_delivery_addresses(
  cust_code   text not null,
  cd_id       int  not null,
  cust_name   text,
  cd_address  text,
  region_id   int,
  region_name text,
  synced_at   timestamptz not null default now(),
  primary key (cust_code, cd_id)
);
alter table public.customer_delivery_addresses enable row level security;
grant select on public.customer_delivery_addresses to authenticated;
grant all on public.customer_delivery_addresses to service_role;
drop policy if exists cda_sel on public.customer_delivery_addresses;
create policy cda_sel on public.customer_delivery_addresses for select to authenticated using (true);

alter table public.customer_region_queue add column if not exists allow_overwrite boolean not null default false;
