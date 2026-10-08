-- migrate_99_purchase_invoices.sql
-- جداول فواتير الشراء المزامَنة من eplus (قاعدة Genius) لكل الفروع.
-- المصدر: pur_trans_h (رأس) + pur_trans_d (بنود) + Vendor (موردين) على SQL Server 2000 بكل فرع.
-- أسماء الأعمدة مطابقة لأسماء eplus الأصلية. الأعمدة المضافة من عندنا: branch, entered_by, itm_name, store_name, line_total, synced_at.
-- الربط: pur_trans_h.pth_id = pur_trans_d.pth_id (مش ptd_id). ven_id→Vendor. itm_id→الصنف (= itm_code عندنا).
-- entered_by = اسم المستخدم الحقيقي من eplus Users.usr_name عبر sec_insert_uid (مش اسم مُخترَع).
-- التواريخ (ven_bill_date/sec_insert_date/sec_update_date) توقيت قاهرة محلي naive — تتخزّن timestamp بدون منطقة وتُقرأ كقاهرة.
-- الكتابة: المزامنة (service_role). القراءة: الشاشات (anon/authenticated).
-- يُطبّق على القاعدتين: الذاتي (supabase.ebrahimhamdy.com) والسحابة (rxtjoqulmgkkcohmgzgi).

-- ═══════════════════════ الموردون (Vendor) ═══════════════════════
create table if not exists public.purchase_vendors (
  branch             text        not null,
  ven_id             integer     not null,
  ven_code           text,
  ven_name_ar        text,
  ven_name_en        text,
  ven_tel            text,
  ven_current_credit numeric(14,2),
  ven_source_tax     numeric(6,3),
  ven_active         text,
  synced_at          timestamptz not null default now(),
  primary key (branch, ven_id)
);

-- ═══════════════════════ رؤوس الفواتير (pur_trans_h) ═══════════════════════
create table if not exists public.purchase_invoices (
  branch           text        not null,                -- الفرع: mamora|san|bishr|seyouf
  pth_id           bigint      not null,                -- رقم الفاتورة في eplus
  sto_id           integer,                             -- المخزن
  store_name       text,                                -- (مضاف) اسم المخزن من Store.sto_name_ar
  ven_id           integer,
  ven_code         text,
  ven_name_ar      text,                                -- (مضاف) من Vendor
  ven_bill_no      text,                                -- رقم فاتورة المورّد
  ven_bill_date    timestamp,                           -- تاريخ الشراء (قاهرة محلي)
  sec_insert_date  timestamp,                           -- وقت الإدخال
  sec_update_date  timestamp,                           -- آخر تعديل (للمزامنة التزايدية)
  sec_insert_uid   integer,                             -- id المستخدم اللي أدخل (Users)
  sec_update_uid   integer,
  emp_id           integer,                             -- الموظف المرتبط بالشراء
  entered_by       text,                                -- (مضاف) Users.usr_name عبر sec_insert_uid
  pur_typ          integer,
  pur_ord_id       bigint,                              -- أمر الشراء (0 = بدون)
  no_of_items      integer,
  total_bill       numeric(14,2),
  total_dis_per    numeric(8,3),
  total_des_mon    numeric(14,2),
  p_other_expenses numeric(14,2),
  pth_source_tax   numeric(14,2),
  total_after_back numeric(14,2),
  pth_paid         numeric(14,2),
  bill_status      integer,
  fh_id            bigint,
  pth_notice       text,
  synced_at        timestamptz not null default now(),
  primary key (branch, pth_id)
);

-- ═══════════════════════ البنود (pur_trans_d) ═══════════════════════
create table if not exists public.purchase_invoice_items (
  branch            text        not null,
  pth_id            bigint      not null,               -- رأس الفاتورة
  ptd_id            bigint      not null,               -- رقم البند داخل الفاتورة (يبدأ من 1، مش معرّف عام)
  itm_id            integer,                            -- = itm_code عندنا
  itm_name          text,                               -- (مضاف) من قاعدتنا/الـAPI
  qnty              numeric(14,3),
  bonus             numeric(14,3),
  itm_pur_price     numeric(14,4),                       -- سعر الشراء
  itm_sell          numeric(14,4),                       -- سعر البيع
  itm_cost          numeric(14,4),                       -- التكلفة
  itm_tax_price     numeric(14,4),                       -- الضريبة
  itm_dis_mon       numeric(14,4),
  itm_dis_per       numeric(8,3),
  line_total        numeric(18,4) generated always as (coalesce(qnty,0)*coalesce(itm_pur_price,0)) stored,
  exp_date          date,
  ptd_batch         text,
  ptd_serial_number text,
  itm_back_qty      numeric(14,3),                       -- كمية المرتجع
  itm_back_pharm    numeric(14,4),                       -- قيمة المرتجع
  c_id              integer,
  synced_at         timestamptz not null default now(),
  primary key (branch, pth_id, ptd_id),
  foreign key (branch, pth_id) references public.purchase_invoices(branch, pth_id) on delete cascade
);

-- ═══════════════════════ فهارس ═══════════════════════
create index if not exists ix_pinv_branch_date on public.purchase_invoices (branch, ven_bill_date desc);
create index if not exists ix_pinv_vendor      on public.purchase_invoices (branch, ven_id);
create index if not exists ix_pinv_update      on public.purchase_invoices (branch, sec_update_date);
create index if not exists ix_pitem_header     on public.purchase_invoice_items (branch, pth_id);
create index if not exists ix_pitem_item       on public.purchase_invoice_items (itm_id);
create index if not exists ix_pitem_exp        on public.purchase_invoice_items (branch, exp_date);

-- ═══════════════════════ الصلاحيات والـRLS ═══════════════════════
alter table public.purchase_vendors        enable row level security;
alter table public.purchase_invoices       enable row level security;
alter table public.purchase_invoice_items  enable row level security;
drop policy if exists p_read on public.purchase_vendors;
drop policy if exists p_read on public.purchase_invoices;
drop policy if exists p_read on public.purchase_invoice_items;
create policy p_read on public.purchase_vendors       for select to anon, authenticated using (true);
create policy p_read on public.purchase_invoices      for select to anon, authenticated using (true);
create policy p_read on public.purchase_invoice_items for select to anon, authenticated using (true);
grant select on public.purchase_vendors        to anon, authenticated;
grant select on public.purchase_invoices        to anon, authenticated;
grant select on public.purchase_invoice_items   to anon, authenticated;
grant all    on public.purchase_vendors         to service_role;
grant all    on public.purchase_invoices         to service_role;
grant all    on public.purchase_invoice_items    to service_role;

notify pgrst, 'reload schema';
