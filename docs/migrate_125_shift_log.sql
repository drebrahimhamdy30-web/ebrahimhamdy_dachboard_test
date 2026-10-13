-- migrate_125_shift_log.sql
-- سجل الشيفتات: مراجعة أي شيفت مقفول (قائمة + تفاصيل) في شاشة تفاصيل الشيفت الحالي.
-- get_shift_log: قائمة الشيفتات المقفولة (من shift_changes) بفلتر فرع/نقطة/تاريخ + ترقيم.
-- get_shift_detail: تفاصيل شيفت واحد = أرقام eplus (الرصيد الإفتتاحى/القيمة/الفعلي/الفرق/التحويل)
--   + حركات الفترة [البداية→التقفيل] من cashier_transactions (مع استبعاد تحويل التسليم الافتتاحي).
-- + تسجيل تبويب «سجل الشيفتات» في نظام صلاحيات التبويبات (منع افتراضي للكاشير/الصيدلي).
-- يُطبّق على السحابة (بيانات الشيفتات هناك).

-- ── قائمة الشيفتات المقفولة ─────────────────────────────────────────
create or replace function public.get_shift_log(
  p_branch text, p_cashier integer default null, p_from date default null,
  p_to date default null, p_limit integer default 30, p_offset integer default 0)
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with s as (
    select sc_id, cashier_id, point_name, shift_start, closed_at,
           round(coalesce(start_cash,0)) opening,
           round(coalesce(curr_cash,0))  system_cash,
           round(coalesce(act_cash,0))   actual_cash,
           round(coalesce(trans_value,0)) transfer,
           round(coalesce(act_cash,0) - coalesce(curr_cash,0)) diff
      from shift_changes
     where (p_branch is null or branch = p_branch)
       and (p_cashier is null or cashier_id = p_cashier)
       and (p_from is null or closed_at::date >= p_from)
       and (p_to   is null or closed_at::date <= p_to)
  )
  select jsonb_build_object(
    'total_count', (select count(*) from s),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.closed_at desc)
                      from (select * from s order by closed_at desc limit p_limit offset p_offset) x), '[]'::jsonb));
$function$;

-- ── تفاصيل شيفت واحد ────────────────────────────────────────────────
create or replace function public.get_shift_detail(p_branch text, p_cashier integer, p_sc_id bigint)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_start timestamp; v_end timestamp; v_open numeric; v_curr numeric; v_act numeric; v_trans numeric; v_pt text; v_skip bigint; v_out jsonb;
begin
  select shift_start, closed_at, coalesce(start_cash,0), coalesce(curr_cash,0), coalesce(act_cash,0), coalesce(trans_value,0), point_name
    into v_start, v_end, v_open, v_curr, v_act, v_trans, v_pt
  from shift_changes where branch=p_branch and cashier_id=p_cashier and sc_id=p_sc_id;
  if not found then return jsonb_build_object('error','الشيفت غير موجود'); end if;
  -- تحويل التسليم الافتتاحي (أول تحويل نقطة→نقطة خلال أول 60 ثانية من البداية = تسليم الشيفت السابق)
  select fh_id into v_skip from cashier_transactions
   where branch=p_branch and from_type=3 and from_id=p_cashier and to_type=3
     and actual_date > v_start and actual_date <= v_start + interval '60 seconds'
   order by actual_date asc limit 1;
  with t as (
    select fh_id, actual_date, amount, is_visa, channel, visa_value, user_name, computer, notes,
      case when from_type=3 and from_id=p_cashier then 'صرف'
           when coalesce(is_visa,0)=1 then 'فيزا'
           when from_type=3 then 'توريد' else 'كاش' end as kind,
      case when to_type=3 and to_id=p_cashier then from_name else to_name end as party
    from cashier_transactions
    where branch=p_branch
      and ((to_type=3 and to_id=p_cashier) or (from_type=3 and from_id=p_cashier))
      and actual_date > v_start and actual_date <= v_end
      and (v_skip is null or fh_id <> v_skip)
  )
  select jsonb_build_object(
    'point', v_pt, 'sc_id', p_sc_id, 'shift_start', v_start, 'closed_at', v_end,
    'opening', round(v_open), 'system_cash', round(v_curr), 'actual_cash', round(v_act),
    'transfer', round(v_trans), 'diff', round(v_act - v_curr),
    'cash_in',  (select coalesce(sum(amount),0) from t where kind='كاش'),
    'visa_in',  (select coalesce(sum(coalesce(visa_value,amount)),0) from t where kind='فيزا'),
    'sarf',     (select coalesce(sum(amount),0) from t where kind='صرف'),
    'transfer_in',(select coalesce(sum(amount),0) from t where kind='توريد'),
    'count',    (select count(*) from t),
    'users', (select coalesce(jsonb_agg(distinct user_name),'[]'::jsonb) from t where user_name is not null),
    'visa_by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel',ch,'total',tot,'cnt',cnt) order by tot desc),'[]'::jsonb)
                        from (select coalesce(channel,'—') ch, sum(coalesce(visa_value,amount)) tot, count(*) cnt from t where kind='فيزا' group by channel) z),
    'transactions', (select coalesce(jsonb_agg(jsonb_build_object('time',to_char(actual_date,'HH24:MI'),'kind',kind,'channel',channel,'party',party,'user_name',user_name,'amount',amount,'computer',computer,'notes',notes,'is_sarf',(kind='صرف')) order by actual_date desc),'[]'::jsonb) from t)
  ) into v_out;
  return v_out;
end$function$;

grant execute on function public.get_shift_log(text,integer,date,date,integer,integer) to anon, authenticated;
grant execute on function public.get_shift_detail(text,integer,bigint) to anon, authenticated;

-- ── تبويب «سجل الشيفتات» في شاشة الصلاحيات ──────────────────────────
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order) values
 ('current_shift','shiftlog','سجل الشيفتات','#tabs .tab[data-mode="log"]',3)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

-- منع افتراضي للأدوار التشغيلية (المالك يفتحه للي محتاجه من شاشة الصلاحيات)
insert into public.tab_permissions (role, page_key, tab_key, allowed) values
 ('cashier','current_shift','shiftlog',false),
 ('pharmacist','current_shift','shiftlog',false)
on conflict (role, page_key, tab_key) do update set allowed = excluded.allowed, updated_at = now();

notify pgrst, 'reload schema';
