-- migrate_188_pending_region_customers.sql
-- دالة تجميع العملاء المحتاجين منطقة (سيرفر) — عشان سكربت الماستر مايحطّش
-- نص عربى فى الـURL (Invoke-RestMethod كان بيفك ترميزه ويبوّظ الفلتر).
-- مُطبّق على السحابة 2026-10-31.

create or replace function public.pending_region_customers(p_since timestamptz default '2026-10-30T00:00:00+02:00')
returns table(cust_code text, branch_id uuid, order_count bigint)
language sql security definer set search_path=public as $$
  select cust_code,
         (array_agg(branch_id order by created_at desc))[1] as branch_id,
         count(*) as order_count
  from public.orders
  where cust_region = 'يحتاج إضافة منطقة'
    and created_at >= p_since
    and cust_code is not null
  group by cust_code
$$;
revoke execute on function public.pending_region_customers(timestamptz) from public;
revoke execute on function public.pending_region_customers(timestamptz) from anon;
grant  execute on function public.pending_region_customers(timestamptz) to service_role;
