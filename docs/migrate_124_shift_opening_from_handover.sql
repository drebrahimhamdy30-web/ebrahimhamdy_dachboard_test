-- migrate_124_shift_opening_from_handover.sql
-- «بداية الفترة» في شاشة تفاصيل الشيفت = «الرصيد الإفتتاحى» في eplus (تقرير تسليم الدرج)
-- = العهدة اللي فتح بيها الشيفت الجديد = sc_curr_cash − sc_trans_value لآخر تقفيل.
-- (sc_trans_value = مبلغ التحويل للخزنة عند التسليم؛ اتأكد على 6 شيفتات: next.start = curr − trans)
--
-- كمان: تحويل التسليم نفسه (أول تحويل لنقطة/خزنة أخرى بعد التقفيل بنفس مبلغ التحويل)
-- بيتبع الشيفت اللي سلّم، فبيتستبعد من حركات الشيفت الحالي عشان الصافي يفضل صح.
-- أمان: لو ماتلقاش تحويل التسليم، تفضل البداية = القيمة (السلوك القديم) والصافي متسق.
--
-- يُطبّق على السحابة (بيانات الشيفتات هناك). الذاتي فاضي من الشيفتات.

-- 1) عمود مبلغ التحويل
alter table public.shift_changes add column if not exists trans_value numeric;

-- 2) إضافة sc_trans_value لـselect مزامنة «shifts»
update public.sync_jobs
set steps = jsonb_set(steps, '{0,select}', to_jsonb(
 'SELECT ''{branch}'' AS branch, sc.sc_id, sc.sc_cashier_id AS cashier_id, cs.fcs_name_ar AS point_name, sc.sc_shift_start_time AS shift_start, sc.sc_start_cash AS start_cash, sc.sc_curr_cash AS curr_cash, sc.sc_act_cash AS act_cash, sc.sc_trans_value AS trans_value, sc.sec_insert_date AS closed_at, sc.sc_to_employee AS to_emp, sc.sc_visa_act_count AS visa_count FROM Shift_Changes sc LEFT JOIN F_Cash_Store cs ON cs.fcs_id = sc.sc_cashier_id'::text))
where id='shifts';

-- 3) إعادة سحب آخر ~60 تقفيل لكل فرع عشان trans_value يتعبّى للصفوف الحالية
update public.sync_branch_state set last_pth = greatest(0, last_pth - 60) where job_id='shifts';

-- 4) get_current_shift: البداية = القيمة − مبلغ التحويل (لو اتلقى تحويل التسليم واتستبعد)
create or replace function public.get_current_shift(p_branch text, p_cashier integer)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_close timestamp; v_curr numeric; v_trans numeric; v_open numeric; v_pt text; v_skip bigint; v_out jsonb;
begin
  select closed_at, curr_cash, trans_value, point_name into v_close, v_curr, v_trans, v_pt
  from shift_changes where branch=p_branch and cashier_id=p_cashier
  order by closed_at desc limit 1;
  v_curr := coalesce(v_curr,0); v_trans := coalesce(v_trans,0);
  v_skip := null;
  if v_trans > 0 and v_close is not null then
    select fh_id into v_skip from cashier_transactions
     where branch=p_branch and from_type=3 and from_id=p_cashier and to_type=3
       and actual_date > v_close and round(amount::numeric,2)=round(v_trans,2)
     order by actual_date asc limit 1;
  end if;
  v_open := v_curr - (case when v_skip is not null then v_trans else 0 end);
  with t as (
    select fh_id, actual_date, amount, is_visa, channel, visa_value, user_name, computer, notes,
      (to_type=3 and to_id=p_cashier) as is_in,
      case when from_type=3 and from_id=p_cashier then -amount else amount end as signed_amt,
      case
        when from_type=3 and from_id=p_cashier then 'صرف'
        when coalesce(is_visa,0)=1 then 'فيزا'
        when from_type=3 then 'توريد'
        else 'كاش' end as kind,
      case when to_type=3 and to_id=p_cashier then from_name else to_name end as party
    from cashier_transactions
    where branch=p_branch
      and ((to_type=3 and to_id=p_cashier) or (from_type=3 and from_id=p_cashier))
      and (v_close is null or actual_date > v_close)
      and (v_skip is null or fh_id <> v_skip)
  )
  select jsonb_build_object(
    'point', coalesce(v_pt,'نقطة '||p_cashier), 'shift_start', v_close, 'opening', v_open,
    'cash_in',  (select coalesce(sum(amount),0) from t where kind='كاش'),
    'visa_in',  (select coalesce(sum(coalesce(visa_value,amount)),0) from t where kind='فيزا'),
    'sarf',     (select coalesce(sum(amount),0) from t where kind='صرف'),
    'transfer_in',(select coalesce(sum(amount),0) from t where kind='توريد'),
    'count',    (select count(*) from t),
    'net_cash', v_open + (select coalesce(sum(amount),0) from t where kind in('كاش','توريد'))
                       - (select coalesce(sum(amount),0) from t where kind='صرف'),
    'account_net', (select coalesce(sum(signed_amt),0) from t),
    'users', (select coalesce(jsonb_agg(distinct user_name),'[]'::jsonb) from t where user_name is not null),
    'visa_by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel',ch,'total',tot,'cnt',cnt) order by tot desc),'[]'::jsonb)
                        from (select coalesce(channel,'—') ch, sum(coalesce(visa_value,amount)) tot, count(*) cnt from t where kind='فيزا' group by channel) z),
    'transactions', (select coalesce(jsonb_agg(jsonb_build_object('time',to_char(actual_date,'HH24:MI'),'kind',kind,'channel',channel,'party',party,'user_name',user_name,'amount',amount,'computer',computer,'notes',notes,'is_sarf',(kind='صرف')) order by actual_date desc),'[]'::jsonb) from t)
  ) into v_out;
  return v_out;
end$function$;

notify pgrst, 'reload schema';
