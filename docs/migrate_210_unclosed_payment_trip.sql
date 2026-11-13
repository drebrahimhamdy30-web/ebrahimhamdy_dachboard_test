-- migrate_210_unclosed_payment_trip.sql
-- تبويب «لم تُغلق على B Connect» في شاشة التوزيع: إضافة طريقة الدفع (payment_method)
-- ومعرّف الرحلة (trip_id) لناتج get_completed_orders_for_bills — عشان بادج الدفع
-- وزر «رحلة الطلب» على الكارت. تغيير RETURNS TABLE يحتاج DROP+CREATE.
-- مُطبّق على السحابة (برودكشن). الذاتي يتطبّق يدويًا لو احتاج.
drop function if exists public.get_completed_orders_for_bills(uuid, text[]);
create function public.get_completed_orders_for_bills(p_branch uuid default null, p_bills text[] default '{}'::text[])
returns table(id uuid, bill_no text, cust_code text, customer_name text, amount numeric, erp_status text,
              created_at timestamptz, driver_name text, cust_region text, customer_address text,
              order_status text, payment_method text, trip_id uuid)
language sql stable security definer set search_path to 'public','extensions','pg_temp'
as $$
  select o.id, o.bill_no, o.cust_code, o.customer_name,
         o.total_bill_net as amount,
         'Pending'::text as erp_status,
         coalesce(o.completed_at, o.updated_at, o.created_at) as created_at,
         coalesce(d.full_name, o.deliveryman) as driver_name,
         o.cust_region, o.customer_address, o.status as order_status,
         o.payment_method,
         (select tox.trip_id from trip_orders tox join trips t on t.id = tox.trip_id
           where tox.order_id = o.id order by (t.status='completed') desc, t.created_at desc limit 1) as trip_id
  from orders o
  left join drivers d on d.id = o.driver_id
  where o.driver_id is not null
    and o.bill_no = any(p_bills)
    and (p_branch is null or o.branch_id = p_branch)
    and ( o.status = 'completed'
      or ( o.status = 'delivered'
           and exists (select 1 from trip_orders tox join trips t on t.id = tox.trip_id
                       where tox.order_id = o.id and t.status = 'completed') ) )
  order by coalesce(o.completed_at, o.updated_at, o.created_at) desc;
$$;
revoke all on function public.get_completed_orders_for_bills(uuid, text[]) from public;
grant execute on function public.get_completed_orders_for_bills(uuid, text[]) to authenticated;
