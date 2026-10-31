-- migrate_187_customer_delivery_pending.sql
-- مصدر الشاشة الحقيقى للعناوين: الطلبات عندنا مفيهاش عنوان، فالعنوان بييجى من
-- eplus (Customer_Delivery). سكربت الماستر بيزامن العناوين الفاضية هنا.
-- + عمود cd_id فى الطابور (الكتابة على سطر العنوان بالظبط، لا تطابق نصّى).
-- + منح service_role (سكربت الماستر بيكتب بيه) — مُطبّق على السحابة 2026-10-31.

create table if not exists public.customer_delivery_pending(
  cust_code   text not null,
  cd_id       int  not null,
  cust_name   text,
  cd_address  text,
  branch_id   uuid,
  order_count int default 0,
  synced_at   timestamptz not null default now(),
  primary key (cust_code, cd_id)
);
alter table public.customer_delivery_pending enable row level security;
grant select on public.customer_delivery_pending to authenticated;
grant all    on public.customer_delivery_pending to service_role;
drop policy if exists cdp_sel on public.customer_delivery_pending;
create policy cdp_sel on public.customer_delivery_pending for select to authenticated using (true);
create index if not exists cdp_branch_idx on public.customer_delivery_pending(branch_id);
create index if not exists cdp_synced_idx on public.customer_delivery_pending(synced_at);

alter table public.customer_region_queue add column if not exists cd_id int;
drop index if exists crq_uniq_pending;
create unique index if not exists crq_uniq_pending_cd
  on public.customer_region_queue(cust_code, cd_id) where status='pending';

-- سكربت الماستر بيقرا/يكتب بالـservice_role (RLS مابيلزمهوش بس الصلاحيات لازمة)
grant all on public.eplus_delivery_regions   to service_role;
grant all on public.customer_region_queue     to service_role;
grant usage, select on all sequences in schema public to service_role;
