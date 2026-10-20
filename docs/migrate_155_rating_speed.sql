/* ═══════════════════════════════════════════════════════════════════
   تقييم العملاء: سؤال ثالث عن سرعة التوصيل
   ═══════════════════════════════════════════════════════════════════
   طلب المالك (2026-10-20): جنب تقييم الصيدلي والمندوب، العميل يقيّم
   سرعة وصول الطلب (1..5). بيتخزّن في `speed_stars` وبيظهر:
     • مؤشر «متوسط سرعة التوصيل» في الترتيب
     • متوسط السرعة جنب كل مندوب (السرعة مسؤولية المندوب والفرع معًا،
       فبتتعرض بجانب المندوب كمعلومة مش كترتيب)
     • نجوم السرعة في التعليقات
   الدالة العامة بتطلب السؤال الثالث إجباريًا زي الاتنين.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

begin;

alter table public.order_rating_links
  add column if not exists speed_stars smallint check (speed_stars between 1 and 5);

create or replace function public.rating_dashboard(p_from date, p_to date, p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_b uuid; v_k jsonb; v_e jsonb; v_d jsonb;
begin
  if public.jwt_app_role() is null
     and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  v_b := public.rating_scope_branch(p_branch_id);

  select jsonb_build_object(
           'sent',       count(*) filter (where l.source = 'batch' and l.sent_at is not null),
           'rated',      count(*) filter (where l.source = 'batch' and l.rated_at is not null),
           'rated_bill', count(*) filter (where l.source = 'bill'  and l.rated_at is not null),
           'avg_employee', round(avg(l.employee_stars)::numeric, 2),
           'avg_driver',   round(avg(l.driver_stars)::numeric, 2),
           'avg_speed',    round(avg(l.speed_stars)::numeric, 2))
    into v_k
    from public.order_rating_links l
   where (coalesce(l.rated_at, l.sent_at) at time zone 'Africa/Cairo')::date between p_from and p_to
     and (v_b is null or l.branch_id = v_b);

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_e
    from (select l.employee_name as name, b.name as branch,
                 round(avg(l.employee_stars)::numeric, 2) as avg, count(*) as n,
                 count(*) filter (where l.source = 'bill') as n_bill
            from public.order_rating_links l
            left join public.branches b on b.id = l.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.employee_name, b.name) x;

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_d
    from (select l.driver_id, coalesce(d.full_name, l.driver_name) as name, b.name as branch,
                 round(avg(l.driver_stars)::numeric, 2) as avg, count(*) as n,
                 count(*) filter (where l.source = 'bill') as n_bill,
                 round(avg(l.speed_stars)::numeric, 2) as avg_speed
            from public.order_rating_links l
            left join public.drivers d on d.id = l.driver_id
            left join public.branches b on b.id = d.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.driver_id, d.full_name, l.driver_name, b.name) x;

  return jsonb_build_object('kpis', v_k, 'employees', v_e, 'drivers', v_d, 'scoped_branch', v_b);
end $fn$;

create or replace function public.rating_comments(p_from date, p_to date, p_branch_id uuid default null,
                                                   p_who text default 'all', p_max_stars int default 5,
                                                   p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_b uuid; v_role text := public.jwt_app_role(); v_total int; v_rows jsonb; v_see boolean;
begin
  select pharmacists_see_comments into v_see from public.rating_settings where id = 1;
  if not (coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
          or v_role in ('admin','manager') or (v_see and v_role is not null)) then
    raise exception 'التعليقات مقصورة على الإدارة' using errcode = '42501';
  end if;
  v_b := public.rating_scope_branch(p_branch_id);

  with f as (
    select l.* from public.order_rating_links l
     where l.rated_at is not null
       and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
       and (v_b is null or l.branch_id = v_b)
       and (p_who = 'all' or (p_who = 'employee' and l.employee_stars <= p_max_stars)
                          or (p_who = 'driver'   and least(l.driver_stars, coalesce(l.speed_stars, 5)) <= p_max_stars))
       and (p_who <> 'all' or least(l.employee_stars, l.driver_stars, coalesce(l.speed_stars, 5)) <= p_max_stars)
  ), pg as (
    select * from f order by rated_at desc
     limit greatest(1, least(200, p_limit)) offset greatest(0, p_offset)
  )
  select (select count(*) from f),
         coalesce((select jsonb_agg(jsonb_build_object(
                     'id', t.id, 'rated_at', t.rated_at, 'bill_no', t.bill_no, 'branch', b.name,
                     'employee_name', t.employee_name, 'employee_stars', t.employee_stars,
                     'driver_name', t.driver_name, 'driver_stars', t.driver_stars,
                     'speed_stars', t.speed_stars, 'comment', t.comment, 'source', t.source)
                   order by t.rated_at desc)
                     from pg t left join public.branches b on b.id = t.branch_id), '[]'::jsonb)
    into v_total, v_rows;

  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $fn$;

notify pgrst, 'reload schema';

commit;
