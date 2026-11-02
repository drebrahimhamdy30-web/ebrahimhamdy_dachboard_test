-- ═══════════════════════════════════════════════════════════════════
--  تقييم العملاء: فلتر «بتعليق فقط» جوّه الدالة
-- ═══════════════════════════════════════════════════════════════════
--  الليه: شاشة التعليقات بتعرض كل التقييمات، والتعليق النصّي هو
--  المفيد فعلًا — الباقي صفوف «بدون تعليق» بتدفن الكلام المكتوب.
--  الفلتر لازم يبقى جوّه الدالة مش في المتصفح: الدالة بترجّع صفحة
--  (limit/offset) وإجمالي، فلو فلترنا بعد الجلب تبقى الصفحة ناقصة
--  والإجمالي غلط وعدد الصفحات غلط.
--
--  p_with_comment:  null = الكل · true = بتعليق فقط · false = بدون تعليق
--
--  ⚠️ إضافة بارامتر بـdefault على دالة كل بارامتراتها لها default
--     بتخلّي النداء القديم غامض (function is not unique)، فلازم
--     نحذف التوقيع القديم بعد إنشاء الجديد. وبعد الإنشاء الدالة
--     بتاخد EXECUTE لـPUBLIC افتراضيًا — بنسحبها فورًا.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.rating_comments(
  p_from date, p_to date, p_branch_id uuid default null::uuid,
  p_who text default 'all'::text, p_max_stars integer default 5,
  p_limit integer default 50, p_offset integer default 0,
  p_with_comment boolean default null
) returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
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
       -- التعليق الفاضي والمسافات لوحدها = بدون تعليق
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

revoke all on function public.rating_comments(date,date,uuid,text,integer,integer,integer,boolean) from public;
grant execute on function public.rating_comments(date,date,uuid,text,integer,integer,integer,boolean) to authenticated, service_role;

-- التوقيع القديم (٧ بارامترات) يتشال عشان النداء مايبقاش غامض
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'rating_comments'
                and p.oid::regprocedure::text like '%,boolean)')
  then
    drop function if exists public.rating_comments(date,date,uuid,text,integer,integer,integer);
  else
    raise exception 'التوقيع الجديد مش موجود — مش هنحذف القديم';
  end if;
end $$;

notify pgrst, 'reload schema';
