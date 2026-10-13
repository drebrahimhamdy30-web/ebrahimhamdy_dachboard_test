-- migrate_130_visa_paid_group.sql
-- إجمالي الفيزا = تجميع «قيمة المدفوع»:
--   * المكتوب يدويًا (visa_no رقم > 1) = «دفعة»؛ كل رقم دفعة مميّز يتحسب مرة واحدة
--     (عشان دفعة 1000 على 3 فواتير بنفس الرقم تتحسب 1000 مرة واحدة، مش 3000).
--   * غير المكتوب (≤1) بياخد القيمة تلقائيًا ويتحسب لكل معاملة على حدة.
-- + ترجيع manual لكل معاملة (عشان الشاشة تميّز المكتوب عن الأوتوماتيك باللون).
-- يُطبّق على السحابة.

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
    select fh_id, actual_date, amount, is_visa, channel, visa_value, visa_no, user_name, computer, notes, from_name, to_name,
      (to_type=3 and to_id=p_cashier) as is_in,
      case when from_type=3 and from_id=p_cashier then -amount else amount end as signed_amt,
      (visa_no ~ '^[0-9]+(\.[0-9]+)?$' and visa_no::numeric > 1) as manual,
      case when visa_no ~ '^[0-9]+(\.[0-9]+)?$' and visa_no::numeric > 1 then visa_no::numeric else amount end as paid_val,
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
    'visa_in',  (select coalesce(sum(val),0) from (select distinct (case when manual then 'm:'||visa_no else 'a:'||fh_id::text end) grp, paid_val val from t where kind='فيزا') d),
    'sarf',     (select coalesce(sum(amount),0) from t where kind='صرف'),
    'transfer_in',(select coalesce(sum(amount),0) from t where kind='توريد'),
    'count',    (select count(*) from t),
    'net_cash', v_open + (select coalesce(sum(amount),0) from t where kind in('كاش','توريد'))
                       - (select coalesce(sum(amount),0) from t where kind='صرف'),
    'account_net', (select coalesce(sum(signed_amt),0) from t),
    'users', (select coalesce(jsonb_agg(distinct user_name),'[]'::jsonb) from t where user_name is not null),
    'visa_by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel',ch,'total',tot,'cnt',cnt) order by tot desc),'[]'::jsonb)
                        from (select ch, sum(val) tot, count(*) cnt from
                                (select distinct coalesce(channel,'—') ch, (case when manual then 'm:'||visa_no else 'a:'||fh_id::text end) grp, paid_val val from t where kind='فيزا') dd
                              group by ch) z),
    'transactions', (select coalesce(jsonb_agg(jsonb_build_object('time',to_char(actual_date,'HH24:MI'),'kind',kind,'channel',channel,'visa_no',visa_no,'paid',paid_val,'manual',manual,'party',party,'from',from_name,'to',to_name,'user_name',user_name,'amount',amount,'computer',computer,'notes',notes,'is_sarf',(kind='صرف')) order by actual_date desc),'[]'::jsonb) from t)
  ) into v_out;
  return v_out;
end$function$;

create or replace function public.get_shift_detail(p_branch text, p_cashier integer, p_sc_id bigint)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_start timestamp; v_end timestamp; v_open numeric; v_curr numeric; v_act numeric; v_trans numeric; v_pt text; v_skip bigint; v_out jsonb;
begin
  select shift_start, closed_at, coalesce(start_cash,0), coalesce(curr_cash,0), coalesce(act_cash,0), coalesce(trans_value,0), point_name
    into v_start, v_end, v_open, v_curr, v_act, v_trans, v_pt
  from shift_changes where branch=p_branch and cashier_id=p_cashier and sc_id=p_sc_id;
  if not found then return jsonb_build_object('error','الشيفت غير موجود'); end if;
  select fh_id into v_skip from cashier_transactions
   where branch=p_branch and from_type=3 and from_id=p_cashier and to_type=3
     and actual_date > v_start and actual_date <= v_start + interval '60 seconds'
   order by actual_date asc limit 1;
  with t as (
    select fh_id, actual_date, amount, is_visa, channel, visa_value, visa_no, user_name, computer, notes, from_name, to_name,
      (visa_no ~ '^[0-9]+(\.[0-9]+)?$' and visa_no::numeric > 1) as manual,
      case when visa_no ~ '^[0-9]+(\.[0-9]+)?$' and visa_no::numeric > 1 then visa_no::numeric else amount end as paid_val,
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
    'visa_in',  (select coalesce(sum(val),0) from (select distinct (case when manual then 'm:'||visa_no else 'a:'||fh_id::text end) grp, paid_val val from t where kind='فيزا') d),
    'sarf',     (select coalesce(sum(amount),0) from t where kind='صرف'),
    'transfer_in',(select coalesce(sum(amount),0) from t where kind='توريد'),
    'count',    (select count(*) from t),
    'users', (select coalesce(jsonb_agg(distinct user_name),'[]'::jsonb) from t where user_name is not null),
    'visa_by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel',ch,'total',tot,'cnt',cnt) order by tot desc),'[]'::jsonb)
                        from (select ch, sum(val) tot, count(*) cnt from
                                (select distinct coalesce(channel,'—') ch, (case when manual then 'm:'||visa_no else 'a:'||fh_id::text end) grp, paid_val val from t where kind='فيزا') dd
                              group by ch) z),
    'transactions', (select coalesce(jsonb_agg(jsonb_build_object('time',to_char(actual_date,'HH24:MI'),'kind',kind,'channel',channel,'visa_no',visa_no,'paid',paid_val,'manual',manual,'party',party,'from',from_name,'to',to_name,'user_name',user_name,'amount',amount,'computer',computer,'notes',notes,'is_sarf',(kind='صرف')) order by actual_date desc),'[]'::jsonb) from t)
  ) into v_out;
  return v_out;
end$function$;

notify pgrst, 'reload schema';
