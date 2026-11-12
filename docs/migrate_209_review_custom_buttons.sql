-- migrate_209_review_custom_buttons.sql
-- أزرار مخصّصة لشاشة مراجعة الصيدلي — تُضاف وتُدار من نفس الشاشة (أدمن/مدير).
-- الزر المخصّص = ملاحظة جاهزة بنصّه: audience='driver' تروح staff_notes (تظهر للطيار)،
-- 'pharmacy' تفضل داخلية. مُطبّق على السحابة؛ الذاتي يتطبّق يدويًا.
create table if not exists public.review_buttons(
  id         bigint generated always as identity primary key,
  label      text not null,
  audience   text not null default 'driver',   -- driver | pharmacy
  is_active  boolean not null default true,
  sort_order int default 0,
  created_by text,
  created_at timestamptz not null default now()
);
alter table public.review_buttons enable row level security;
grant select, insert, update, delete on public.review_buttons to authenticated;
grant all on public.review_buttons to service_role;
drop policy if exists rb_all on public.review_buttons;
create policy rb_all on public.review_buttons for all to authenticated using(true) with check(true);
