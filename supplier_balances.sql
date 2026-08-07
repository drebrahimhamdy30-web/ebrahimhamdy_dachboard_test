-- ============================================================
-- متابعة أرصدة الموردين (Supplier Balance Watch) — سكيمة القاعدة
-- مُطبّقة على Supabase عبر migration باسم: supplier_balance_watch
-- محفوظة هنا للمرجعية فقط (نفس محتوى الميجريشن).
--
-- ملاحظات مهمة:
--  * snapshots + runs = APPEND-ONLY: SELECT/INSERT فقط، لا UPDATE ولا DELETE إطلاقًا.
--    المرجع الحالي = أحدث صف للفرع (بـ taken_at). "التراجع" = إضافة صف جديد (kind='undo')
--    ينسخ السناب شوت الأقدم ويشاور عليه بـ restored_from — مش تعديل/حذف.
--  * الفرع يتعرّف بالاسم العربي (نفس ما يستخدمه باقي الأبلكيشن: userBranch).
--  * RLS مفتوحة بنفس أسلوب باقي جداول الأبلكيشن (anon/authenticated). التحقق الحقيقي
--    كله client-side وبنفس مستوى باقي الأبلكيشن — لا أقوى ولا أعلى. المفتاح anon عام.
-- ============================================================

create table if not exists public.supplier_balance_snapshots (
  id            bigint generated always as identity primary key,
  branch        text        not null,
  taken_at      timestamptz not null default now(),
  taken_by      text,
  rows          jsonb       not null default '{}'::jsonb,
  rows_count    integer     not null default 0,
  kind          text        not null default 'import',   -- 'import' | 'undo'
  restored_from bigint       references public.supplier_balance_snapshots(id)
);
create index if not exists idx_supbal_snap_branch_taken
  on public.supplier_balance_snapshots (branch, taken_at desc);

create table if not exists public.supplier_balance_runs (
  id            bigint generated always as identity primary key,
  branch        text        not null,
  run_at        timestamptz not null default now(),
  run_by        text,
  changed_count integer     not null default 0,
  added_count   integer     not null default 0,
  removed_count integer     not null default 0,
  result        jsonb       not null default '{}'::jsonb,
  snapshot_id   bigint       references public.supplier_balance_snapshots(id)
);
create index if not exists idx_supbal_runs_branch_runat
  on public.supplier_balance_runs (branch, run_at desc);

create table if not exists public.supplier_balance_exclusions (
  supplier_code text primary key,
  note          text,
  created_by    text,
  created_at    timestamptz not null default now()
);

create table if not exists public.supplier_balance_settings (
  id         integer primary key default 1,
  threshold  numeric     not null default 0.01,
  updated_by text,
  updated_at timestamptz not null default now(),
  constraint supbal_settings_singleton check (id = 1)
);
insert into public.supplier_balance_settings (id, threshold)
values (1, 0.01) on conflict (id) do nothing;

-- ===== RLS: مفتوحة زي باقي الأبلكيشن، لكن snapshots/runs بدون UPDATE/DELETE =====
alter table public.supplier_balance_snapshots  enable row level security;
alter table public.supplier_balance_runs        enable row level security;
alter table public.supplier_balance_exclusions  enable row level security;
alter table public.supplier_balance_settings    enable row level security;

drop policy if exists supbal_snap_select on public.supplier_balance_snapshots;
drop policy if exists supbal_snap_insert on public.supplier_balance_snapshots;
create policy supbal_snap_select on public.supplier_balance_snapshots for select to anon, authenticated using (true);
create policy supbal_snap_insert on public.supplier_balance_snapshots for insert to anon, authenticated with check (true);

drop policy if exists supbal_runs_select on public.supplier_balance_runs;
drop policy if exists supbal_runs_insert on public.supplier_balance_runs;
create policy supbal_runs_select on public.supplier_balance_runs for select to anon, authenticated using (true);
create policy supbal_runs_insert on public.supplier_balance_runs for insert to anon, authenticated with check (true);

drop policy if exists supbal_excl_all on public.supplier_balance_exclusions;
create policy supbal_excl_all on public.supplier_balance_exclusions for all to anon, authenticated using (true) with check (true);

drop policy if exists supbal_settings_select on public.supplier_balance_settings;
drop policy if exists supbal_settings_insert on public.supplier_balance_settings;
drop policy if exists supbal_settings_update on public.supplier_balance_settings;
create policy supbal_settings_select on public.supplier_balance_settings for select to anon, authenticated using (true);
create policy supbal_settings_insert on public.supplier_balance_settings for insert to anon, authenticated with check (true);
create policy supbal_settings_update on public.supplier_balance_settings for update to anon, authenticated using (true) with check (true);

grant select, insert on public.supplier_balance_snapshots to anon, authenticated;
grant select, insert on public.supplier_balance_runs       to anon, authenticated;
grant select, insert, delete on public.supplier_balance_exclusions to anon, authenticated;
grant select, insert, update on public.supplier_balance_settings   to anon, authenticated;

-- ===== سلامة اسم الفرع: FK على جدول branches (يمنع أي فرع وهمي من نص حر غلط) =====
-- عمود branch نص، فالقيد ده بيضمن إنه لازم يساوي اسم فرع موجود فعلًا (بالحرف والمسافة).
-- ON UPDATE CASCADE: لو الفرع اتعاد تسميته، الصفوف تتحدّث. الحذف RESTRICT (مينفعش تمسح فرع ليه تاريخ).
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.branches'::regclass and conname='branches_name_key') then
    alter table public.branches add constraint branches_name_key unique (name);
  end if;
end $$;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.supplier_balance_snapshots'::regclass and conname='supbal_snap_branch_fk') then
    alter table public.supplier_balance_snapshots
      add constraint supbal_snap_branch_fk foreign key (branch) references public.branches(name) on update cascade;
  end if;
end $$;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.supplier_balance_runs'::regclass and conname='supbal_runs_branch_fk') then
    alter table public.supplier_balance_runs
      add constraint supbal_runs_branch_fk foreign key (branch) references public.branches(name) on update cascade;
  end if;
end $$;

-- ===== تسجيل الصفحة في الصلاحيات — للأدمن فقط افتراضيًا (view + edit) =====
insert into public.page_permissions (role, page, can_view, can_edit, sort_order)
values ('admin', 'supplier_balances.html', true, true, 145)
on conflict (role, page) do nothing;
