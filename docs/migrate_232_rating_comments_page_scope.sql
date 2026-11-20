-- migrate_232_rating_comments_page_scope.sql
-- التعليقات: مين له صلاحية فتح شاشة ratings.html (can_view) يشوفها عادي —
-- بدل القصر على admin/manager أو إعداد pharmacists_see_comments.
-- قرار المالك 2026-11-20: اللي الشاشة مفتوحة له يشوف التعليقات عادي.
-- بيصلّح كمان تضارب كان الموظف بيشوف التبويب بس السيرفر يرفض نداءه.
create or replace function public.rating_comments(
  p_from date, p_to date, p_branch_id uuid default null::uuid,
  p_who text default 'all'::text, p_max_stars integer default 5,
  p_limit integer default 50, p_offset integer default 0,
  p_with_comment boolean default null::boolean)
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_b uuid; v_role text := public.jwt_app_role(); v_total int; v_rows jsonb;
begin
  if not (coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
          or v_role = 'admin'
          or exists (select 1 from public.page_permissions pp
                      where pp.page = 'ratings.html' and pp.role = v_role and pp.can_view)) then
    raise exception 'التعليقات مقصورة على من له صلاحية فتح شاشة التقييمات' using errcode = '42501';
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
       and (p_with_comment is null
            or (p_with_comment     and coalesce(btrim(l.comment), '') <> '')
            or (not p_with_comment and coalesce(btrim(l.comment), '')  = ''))
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
end $function$;
