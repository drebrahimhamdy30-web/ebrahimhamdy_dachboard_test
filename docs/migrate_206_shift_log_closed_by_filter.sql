-- ═══════════════════════════════════════════════════════════════════
--  سجل الشيفتات: عرض اللي قفل + فلتر بيه
-- ═══════════════════════════════════════════════════════════════════
--  ⚠️ التوقيع بيتغيّر (بارامتر `p_employee` زيادة). `create or replace`
--     **مابيستبدلش** دالة بتوقيع مختلف — بيعمل نسخة تانية جنبها،
--     و PostgREST يتلخبط بين الاتنين. فالقديمة بتتشال صراحةً.
--
--  وقايمة الموظفين بترجع من السيرفر مع الرد، لسببين:
--  · لو اتبنت في المتصفح من صفحة الـ30 صف، نص الموظفين مش هيبانوا
--    ([[data-layer-1000-cap]]).
--  · وبتتبني من `base` **قبل** فلتر الموظف — لو اتبنت بعده، أول
--    اختيار كان هيقصّ القايمة على الشخص ده ومايبقاش في رجوع.
-- ═══════════════════════════════════════════════════════════════════

drop function if exists public.get_shift_log(text, integer, date, date, integer, integer);

create or replace function public.get_shift_log(
  p_branch   text,
  p_cashier  integer default null,
  p_from     date    default null,
  p_to       date    default null,
  p_limit    integer default 30,
  p_offset   integer default 0,
  p_employee text    default null
)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with base as (
    select sc_id, cashier_id, point_name, shift_start, closed_at,
           nullif(btrim(coalesce(closed_by,'')), '') closed_by,
           round(coalesce(start_cash,0)) opening,
           round(coalesce(curr_cash,0))  system_cash,
           round(coalesce(act_cash,0))   actual_cash,
           round(coalesce(trans_value,0)) transfer,
           round(coalesce(curr_cash,0) - coalesce(start_cash,0)) period,
           round((coalesce(curr_cash,0) - coalesce(start_cash,0)) - coalesce(act_cash,0)) diff
      from shift_changes
     where (p_branch is null or branch = p_branch)
       and (p_cashier is null or cashier_id = p_cashier)
       and (p_from is null or closed_at::date >= p_from)
       and (p_to   is null or closed_at::date <= p_to)
  ),
  s as (
    select * from base
     where (p_employee is null or p_employee = '' or closed_by = p_employee)
  )
  select jsonb_build_object(
    'total_count', (select count(*) from s),
    'total_diff',  (select coalesce(sum(diff),0) from s),
    'total_up',    (select coalesce(sum(diff) filter (where diff > 0),0) from s),
    'total_down',  (select coalesce(sum(diff) filter (where diff < 0),0) from s),
    'employees', (select coalesce(jsonb_agg(distinct closed_by order by closed_by), '[]'::jsonb)
                    from base where closed_by is not null),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.closed_at desc)
                      from (select * from s order by closed_at desc limit p_limit offset p_offset) x), '[]'::jsonb));
$function$;

revoke all on function public.get_shift_log(text, integer, date, date, integer, integer, text) from public;
grant execute on function public.get_shift_log(text, integer, date, date, integer, integer, text) to authenticated;
