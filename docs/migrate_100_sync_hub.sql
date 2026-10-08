-- migrate_100_sync_hub.sql
-- مركز المزامنة: محرّك عام مدفوع بالبيانات (جدول مهام) بدل سكربت لكل جدول.
-- المحرّك: scripts/sync_engine.ps1 (PowerShell على جهاز الفرع، نبضة كل 1-2 د، قراءة فقط من eplus).
-- يعتمد على جداول المشتريات (migrate_99). يُطبّق على القاعدتين (الذاتي + السحابة).
-- البيانات الحيّة على السحابة؛ الذاتي ياخد الكود (الجداول فاضية للتطوير).

-- ═══════════════════════ جداول التحكم ═══════════════════════
create table if not exists public.sync_jobs (
  id               text primary key,
  name             text not null,
  source_db        text default 'Genius',
  enabled          boolean not null default true,
  interval_minutes integer not null default 5,
  window_days      integer not null default 2,
  window_refresh_minutes integer not null default 20,
  steps            jsonb not null default '[]'::jsonb,
  post_rpc         text,
  last_run_at      timestamptz,
  last_status      text,
  sort_order       integer default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table if not exists public.sync_branch_state (
  job_id       text not null references public.sync_jobs(id) on delete cascade,
  branch       text not null,
  enabled      boolean not null default false,
  last_pth     bigint default 0,
  last_window_at timestamptz,
  last_sync_at timestamptz,
  last_status  text,
  rows_last    integer,
  updated_at   timestamptz not null default now(),
  primary key (job_id, branch)
);

create table if not exists public.sync_runs (
  id          bigserial primary key,
  job_id      text,
  branch      text,
  kind        text default 'auto',
  new_rows    integer,
  item_rows   integer,
  duration_ms integer,
  status      text,
  error       text,
  ran_at      timestamptz not null default now()
);
create index if not exists ix_sync_runs_time on public.sync_runs (ran_at desc);

create table if not exists public.sync_requests (
  id          bigserial primary key,
  job_id      text not null,
  branch      text,
  kind        text not null default 'manual',
  from_date   date,
  to_date     date,
  status      text not null default 'pending',
  message     text,
  requested_at timestamptz not null default now(),
  done_at     timestamptz
);
create index if not exists ix_sync_req_pending on public.sync_requests (status, requested_at);

-- ═══════════════════════ RLS + صلاحيات ═══════════════════════
alter table public.sync_jobs         enable row level security;
alter table public.sync_branch_state enable row level security;
alter table public.sync_runs         enable row level security;
alter table public.sync_requests     enable row level security;
drop policy if exists p_read on public.sync_jobs;
drop policy if exists p_read on public.sync_branch_state;
drop policy if exists p_read on public.sync_runs;
drop policy if exists p_read on public.sync_requests;
create policy p_read on public.sync_jobs         for select to anon, authenticated using (true);
create policy p_read on public.sync_branch_state for select to anon, authenticated using (true);
create policy p_read on public.sync_runs         for select to anon, authenticated using (true);
create policy p_read on public.sync_requests     for select to anon, authenticated using (true);
grant select on public.sync_jobs, public.sync_branch_state, public.sync_runs, public.sync_requests to anon, authenticated;
grant all on public.sync_jobs, public.sync_branch_state, public.sync_runs, public.sync_requests to service_role;
grant usage, select on sequence public.sync_runs_id_seq     to service_role;
grant usage, select on sequence public.sync_requests_id_seq to service_role;

-- ═══════════════════════ مهمة المشتريات ═══════════════════════
insert into public.sync_jobs (id,name,enabled,interval_minutes,window_days,window_refresh_minutes,post_rpc,sort_order,steps)
values (
 'purchases','المشتريات', true, 5, 2, 20, 'enrich_purchase_item_names', 1,
 jsonb_build_array(
   jsonb_build_object(
     'target','purchase_vendors','conflict','branch,ven_id',
     'select', $s$SELECT '{branch}' AS branch, ven_id, ven_code, ven_name_ar, ven_name_en, ven_tel, ven_current_credit, ven_source_tax, ven_active FROM Vendor$s$
   ),
   jsonb_build_object(
     'target','purchase_invoices','conflict','branch,pth_id',
     'probe_max','SELECT MAX(pth_id) FROM pur_trans_h',
     'where_window', $w$h.sec_insert_date >= '{cut}' OR h.sec_update_date >= '{cut}'$w$,
     'where_new','h.pth_id > {last_pth}',
     'where_range', $r$h.ven_bill_date >= '{from}' AND h.ven_bill_date < '{to}'$r$,
     'select', $s$SELECT '{branch}' AS branch, h.pth_id, h.sto_id, s.sto_name_ar AS store_name, h.ven_id, v.ven_code, v.ven_name_ar, h.ven_bill_no, h.ven_bill_date, h.sec_insert_date, h.sec_update_date, h.sec_insert_uid, h.sec_update_uid, h.emp_id, e.e_Name AS entered_by, h.pur_typ, h.pur_ord_id, h.no_of_items, h.total_bill, h.total_dis_per, h.total_des_mon, h.p_other_expenses, h.pth_source_tax, h.total_after_back, h.pth_paid, h.bill_status, h.fh_id, h.pth_notice FROM pur_trans_h h LEFT JOIN Vendor v ON v.ven_id=h.ven_id LEFT JOIN Employee e ON e.e_id=h.emp_id LEFT JOIN Store s ON s.sto_id=h.sto_id$s$
   ),
   jsonb_build_object(
     'target','purchase_invoice_items','conflict','branch,pth_id,ptd_id',
     'where_window', $w$h.sec_insert_date >= '{cut}' OR h.sec_update_date >= '{cut}'$w$,
     'where_new','d.pth_id > {last_pth}',
     'where_range', $r$h.ven_bill_date >= '{from}' AND h.ven_bill_date < '{to}'$r$,
     'select', $s$SELECT '{branch}' AS branch, d.pth_id, d.ptd_id, d.itm_id, d.qnty, d.bonus, d.itm_pur_price, d.itm_sell, d.itm_cost, d.itm_tax_price, d.itm_dis_mon, d.itm_dis_per, d.exp_date, d.ptd_batch, d.ptd_serial_number, d.itm_back_qty, d.itm_back_pharm, d.c_id FROM pur_trans_d d JOIN pur_trans_h h ON h.pth_id=d.pth_id$s$
   )
 )
)
on conflict (id) do update set name=excluded.name, steps=excluded.steps, post_rpc=excluded.post_rpc,
  interval_minutes=excluded.interval_minutes, window_days=excluded.window_days,
  window_refresh_minutes=excluded.window_refresh_minutes, updated_at=now();

insert into public.sync_branch_state (job_id,branch,enabled) values
 ('purchases','mamora', false),  -- يتفعّل من الشاشة بعد تجهيز الفرع
 ('purchases','san',   false),
 ('purchases','bishr', false),
 ('purchases','seyouf',false)
on conflict (job_id,branch) do nothing;

-- ═══════════════════════ دالة إثراء الأسماء ═══════════════════════
create or replace function public.enrich_purchase_item_names()
returns integer language plpgsql security definer set search_path=public as $$
declare total integer := 0; n integer;
begin
  begin
    update public.purchase_invoice_items pi set itm_name = s.itm_name_ar
    from public.sales_items s where pi.itm_name is null and s.itm_code = pi.itm_id::text and s.itm_name_ar is not null and s.itm_name_ar<>'';
    get diagnostics n = row_count; total := total + n;
  exception when others then null; end;
  begin
    update public.purchase_invoice_items pi set itm_name = m.itm_name
    from public.monthly_sales m where pi.itm_name is null and m.itm_code = pi.itm_id::text and m.itm_name is not null and m.itm_name<>'';
    get diagnostics n = row_count; total := total + n;
  exception when others then null; end;
  begin
    update public.purchase_invoice_items pi set itm_name = b.itm_name_ar
    from public.branch_stock b where pi.itm_name is null and b.itm_code = pi.itm_id::text and b.itm_name_ar is not null and b.itm_name_ar<>'';
    get diagnostics n = row_count; total := total + n;
  exception when others then null; end;
  return total;
end$$;
grant execute on function public.enrich_purchase_item_names() to service_role;

-- ═══════════════════════ دوال التحكم (أدمن/مدير) ═══════════════════════
create or replace function public.sync_request(p_job text, p_branch text default null, p_kind text default 'manual', p_from date default null, p_to date default null)
returns bigint language plpgsql security definer set search_path=public as $$
declare rid bigint;
begin
  perform require_app_role(array['admin','manager']::text[]);
  if p_kind not in ('manual','backfill') then raise exception 'نوع غير صحيح'; end if;
  insert into public.sync_requests(job_id,branch,kind,from_date,to_date)
  values (p_job, nullif(p_branch,''), p_kind, p_from, p_to) returning id into rid;
  return rid;
end$$;

create or replace function public.sync_set_job(p_id text, p_enabled boolean default null, p_interval integer default null, p_window_days integer default null, p_window_refresh integer default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform require_app_role(array['admin','manager']::text[]);
  update public.sync_jobs set
    enabled = coalesce(p_enabled, enabled),
    interval_minutes = coalesce(p_interval, interval_minutes),
    window_days = coalesce(p_window_days, window_days),
    window_refresh_minutes = coalesce(p_window_refresh, window_refresh_minutes),
    updated_at = now()
  where id = p_id;
end$$;

create or replace function public.sync_set_branch(p_job text, p_branch text, p_enabled boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform require_app_role(array['admin','manager']::text[]);
  update public.sync_branch_state set enabled = p_enabled, updated_at = now() where job_id = p_job and branch = p_branch;
  if not found then insert into public.sync_branch_state(job_id,branch,enabled) values (p_job,p_branch,p_enabled); end if;
end$$;

revoke all on function public.sync_request(text,text,text,date,date) from public, anon;
revoke all on function public.sync_set_job(text,boolean,integer,integer,integer) from public, anon;
revoke all on function public.sync_set_branch(text,text,boolean) from public, anon;
grant execute on function public.sync_request(text,text,text,date,date) to authenticated;
grant execute on function public.sync_set_job(text,boolean,integer,integer,integer) to authenticated;
grant execute on function public.sync_set_branch(text,text,boolean) to authenticated;

-- ═══════════════════════ تسجيل الشاشة ═══════════════════════
INSERT INTO app_pages (key, file, title, section, sort_order, is_active)
VALUES ('sync_hub','sync_hub.html','مركز المزامنة','المشتريات',300,true)
ON CONFLICT (key) DO UPDATE SET file=excluded.file, title=excluded.title, section=excluded.section, sort_order=excluded.sort_order, is_active=true;

INSERT INTO page_permissions (page, role, can_view, can_edit, page_key, sort_order)
SELECT 'sync_hub.html', r, r in ('admin','manager'), r in ('admin','manager'), 'sync_hub', 1
  FROM unnest(array['admin','manager','employee','pharmacist','cashier','accountant','reviewer','inventory','supervisor']) r
 WHERE NOT EXISTS (SELECT 1 FROM page_permissions WHERE page_key='sync_hub' AND role=r);

notify pgrst, 'reload schema';
