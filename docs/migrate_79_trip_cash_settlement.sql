-- migrate_79_trip_cash_settlement.sql
-- تأكيد المبلغ الكاش المستلم من الطيار لكل رحلة (سجل مستقل)
-- الكاشير/المدير/الأدمن بيأكد المبلغ المجمّع تلقائيًا من طلبات الرحلة الكاش.
-- أي تغيير بعدها في طريقة الدفع أو قيمة التحصيل أو اعتمادها → يلغي التأكيد تلقائيًا (تريجر).
-- يُطبَّق على القاعدتين: السحابة + السيرفر الذاتي.

create table if not exists public.trip_cash_settlement (
  trip_id uuid primary key references public.trips(id) on delete cascade,
  driver_id uuid,
  branch_id uuid,
  confirmed_amount numeric not null default 0,
  confirmed_by text,
  confirmed_at timestamptz not null default now()
);

grant select, insert, update, delete on public.trip_cash_settlement to anon, authenticated;

alter table public.trip_cash_settlement enable row level security;
drop policy if exists tcs_all on public.trip_cash_settlement;
create policy tcs_all on public.trip_cash_settlement for all to anon, authenticated using (true) with check (true);

-- إلغاء التأكيد تلقائيًا لو اتغيّرت طريقة الدفع أو قيمة التحصيل أو اعتمادها لأي طلب في الرحلة
create or replace function public.invalidate_trip_cash_on_order_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (new.payment_method is distinct from old.payment_method)
     or (new.collected_amount is distinct from old.collected_amount)
     or (new.collected_approved is distinct from old.collected_approved) then
    delete from public.trip_cash_settlement s
      where s.trip_id in (select trip_id from public.trip_orders where order_id = new.id);
  end if;
  return new;
end $$;

drop trigger if exists trg_invalidate_trip_cash on public.orders;
create trigger trg_invalidate_trip_cash
  after update of payment_method, collected_amount, collected_approved on public.orders
  for each row execute function public.invalidate_trip_cash_on_order_change();
