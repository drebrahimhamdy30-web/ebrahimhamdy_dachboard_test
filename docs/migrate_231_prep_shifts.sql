-- migrate_231_prep_shifts.sql
-- شيفت التحضير (نفس فكرة review_shifts): المحضّر يكتب اسمه فيبدأ شيفت تحضير،
-- والإشعارات بظهور طلب جديد للتحضير تشتغل أثناء الشيفت، وتُنهى بإنهاء الشيفت.
-- branch_id uuid (زي orders.branch_id/branches.id). على السحابة + الذاتي.
create table if not exists public.prep_shifts(
  id            bigint generated always as identity primary key,
  preparer_name text not null,
  branch_id     uuid,
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,
  started_by    text
);
alter table public.prep_shifts enable row level security;
grant select, insert, update on public.prep_shifts to authenticated;
grant all on public.prep_shifts to service_role;
drop policy if exists ps_all on public.prep_shifts;
create policy ps_all on public.prep_shifts for all to authenticated using (true) with check (true);
create index if not exists ps_open_idx on public.prep_shifts(started_at) where ended_at is null;
