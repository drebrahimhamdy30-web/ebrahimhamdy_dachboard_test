/* migrate_215 — فلتر «لم يصرف» في مراجعة تحصيل بطاقات الائتمان
   الليه: شريط «يتطلب مراجعة» بيجيب «بلا تفسير» غير المُراجَعة بس، فالمعاملة
   المطابَقة اللي لم تُصرف مكانش فيه طريقة توصلها — ولا حتى في شيفت قديم،
   لأن شاشة الشيفت الحالي مقصورة على الشيفت المفتوح من السيرفر.
   الدالة بترجع pending/pending_paid أصلًا، الناقص كان الفلتر نفسه.
   التعديل: سطر واحد في الـCTE اسمه f + عدّادين للشريط. الباقي نسخة حرفية. */
CREATE OR REPLACE FUNCTION public.get_card_review(p_branch text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_state text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from date; v_to date; v_lim int; v_off int; v_br text; v_role text; v_all boolean;
  v_out jsonb;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  v_role := public.jwt_app_role();
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
     or v_role = 'admin' then
    v_br := nullif(btrim(coalesce(p_branch,'')),'');
  else
    select pp.all_branches into v_all from page_permissions pp
     where pp.role = v_role and pp.page_key = 'current_shift';
    if coalesce(v_all,false) then v_br := nullif(btrim(coalesce(p_branch,'')),'');
    else v_br := coalesce(public.branch_code_of(public.jwt_branch()), '__none__'); end if;
  end if;

  v_from := coalesce(p_from, (now() at time zone 'Africa/Cairo')::date);
  v_to   := coalesce(p_to,   (now() at time zone 'Africa/Cairo')::date);
  v_lim  := greatest(1, least(coalesce(p_limit, 50), 200));
  v_off  := greatest(0, coalesce(p_offset, 0));

  with
  t as (
    select c.branch, c.fh_id, c.actual_date, c.amount, c.channel, c.visa_no, c.visa_name, c.sth_id,
           c.user_name, c.computer, c.notes, c.from_name, c.to_name, c.cust_name, c.cust_code,
           (c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1) as manual,
           case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then c.visa_no::numeric else c.amount end as paid_val,
           r.reviewed_by, r.reviewed_at, r.paid as rv_paid, r.channel as rv_channel, r.note as rv_note, r.note_src as rv_src,
           case when c.channel ~* '^paymob'                   then 'machine'
                when c.channel ~* 'vodaf|orange|wee|etisalat' then 'sms'
                else 'none' end as feed
      from cashier_transactions c
      left join shift_txn_reviews r on r.branch = c.branch and r.fh_id = c.fh_id
     where coalesce(c.is_visa,0) = 1
       and (c.actual_date at time zone 'Africa/Cairo')::date between v_from and v_to
       and (v_br is null or c.branch = v_br)
  ),
  wm as (
    select public.branch_code_of(branch) as bc, "createdAt" as ts,
           round(ammount,2) as amt, machine_name, order_id
      from wallet
     where ("createdAt" at time zone 'Africa/Cairo')::date between v_from - 1 and v_to + 1
  ),
  ws as (
    select public.branch_code_of(branch) as bc, "createdAt" as ts,
           round(ammount,2) as amt, to_no, op_ref
      from wallet_sms
     where type = 'استلام'
       and ("createdAt" at time zone 'Africa/Cairo')::date between v_from - 1 and v_to + 1
  ),
  gaps as (select * from public.wallet_sms_gaps(v_from, v_to)),
  tm as (select *, row_number() over (partition by branch, paid_val order by actual_date, fh_id) rk
           from t where feed = 'machine'),
  wmr as (select *, row_number() over (partition by bc, amt order by ts) rk from wm),
  ts2 as (select *, row_number() over (partition by branch, paid_val order by actual_date, fh_id) rk
            from t where feed = 'sms'),
  wsr as (select *, row_number() over (partition by bc, amt order by ts) rk from ws),
  mm as (
    select tm.fh_id, tm.branch, 'ماكينة ' || coalesce(w.machine_name, '') ||
           coalesce(' · ' || nullif(w.order_id,''), '') as ev
      from tm join wmr w on w.bc = tm.branch and w.amt = tm.paid_val and w.rk = tm.rk
     where abs(extract(epoch from w.ts - tm.actual_date)) <= 7200
  ),
  ms as (
    select ts2.fh_id, ts2.branch, 'محفظة ' || coalesce(s.to_no,'') ||
           coalesce(' · ' || nullif(s.op_ref,''), '') as ev
      from ts2 join wsr s on s.bc = ts2.branch and s.amt = ts2.paid_val and s.rk = ts2.rk
     where abs(extract(epoch from s.ts - ts2.actual_date)) <= 7200
  ),
  hit as (select * from mm union all select * from ms),
  ot as (select t.* from t where not exists (select 1 from hit h where h.fh_id = t.fh_id and h.branch = t.branch)),
  sp as (
    select o.fh_id, o.branch, w.party, round(abs(w.amt - o.paid_val),2) dv,
           round(abs(extract(epoch from w.ts - o.actual_date))/60)::int dm,
           row_number() over (partition by o.branch, o.fh_id
             order by abs(w.amt - o.paid_val), abs(extract(epoch from w.ts - o.actual_date))) rn
      from ot o
      join (select bc, ts, amt, 'ماكينة ' || coalesce(machine_name,'') as party from wm
            union all
            select bc, ts, amt, 'محفظة ' || coalesce(to_no,'') from ws) w
        on w.bc = o.branch
     where abs(w.amt - o.paid_val) <= 5
       and abs(extract(epoch from w.ts - o.actual_date)) <= 7200
  ),
  sugg as (select * from sp where rn = 1),
  j as (
    select t.*, h.ev,
           case when h.fh_id is null and sg.fh_id is not null
                then sg.party || ' (' ||
                     case when sg.dv > 0 then 'فرق ' || sg.dv::text || ' ج · ' else '' end ||
                     'بفارق ' || sg.dm::text || ' دقيقة)' end as sugg_t,
           case
             when t.feed = 'none' then 'no_feed'
             when h.fh_id is not null then 'matched'
             when t.feed = 'sms' and exists (
                    select 1 from gaps g where g.branch_code = t.branch
                     and t.actual_date between g.gap_from and g.gap_to) then 'feed_gap'
             when t.feed = 'machine' and not exists (
                    select 1 from wm w where w.bc = t.branch
                     and abs(extract(epoch from w.ts - t.actual_date)) <= 7200) then 'feed_gap'
             when t.feed = 'sms' and not exists (
                    select 1 from ws s where s.bc = t.branch
                     and abs(extract(epoch from s.ts - t.actual_date)) <= 7200) then 'feed_gap'
             else 'unexplained'
           end as state
      from t left join hit h on h.fh_id = t.fh_id and h.branch = t.branch
             left join sugg sg on sg.fh_id = t.fh_id and sg.branch = t.branch
  ),
  f as (
    select * from j
     where p_state is null
        or (p_state = 'pending' and state = 'unexplained' and reviewed_by is null)
        or (p_state = 'unpaid' and reviewed_by is null)
        or state = p_state
  )
  select jsonb_build_object(
    'total',         (select count(*) from f),
    'total_paid',    (select coalesce(sum(paid_val),0) from f),
    'reviewed',      (select count(*) from f where reviewed_by is not null),
    'reviewed_paid', (select coalesce(sum(coalesce(rv_paid, paid_val)),0) from f where reviewed_by is not null),
    'pending',       (select count(*) from f where reviewed_by is null),
    'pending_paid',  (select coalesce(sum(paid_val),0) from f where reviewed_by is null),
    'needs_review', (select count(*) from j where state = 'unexplained' and reviewed_by is null),
    'needs_review_val', (select coalesce(round(sum(paid_val)),0) from j where state = 'unexplained' and reviewed_by is null),
    'unpaid_n',   (select count(*) from j where reviewed_by is null),
    'unpaid_val', (select coalesce(round(sum(paid_val)),0) from j where reviewed_by is null),
    'states', (select coalesce(jsonb_object_agg(state, jsonb_build_array(n, v)), '{}'::jsonb)
                 from (select state, count(*) n, round(sum(paid_val)) v from j group by state) q),
    'branches', (select coalesce(jsonb_agg(distinct branch),'[]'::jsonb) from f),
    'channels', (select coalesce(jsonb_agg(distinct coalesce(channel,'—')),'[]'::jsonb) from f),
    'users',    (select coalesce(jsonb_agg(distinct user_name) filter (where user_name is not null),'[]'::jsonb) from f),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'fh_id', fh_id, 'branch', branch,
        'rv', case when reviewed_by is null then null else jsonb_build_object(
                 'by', reviewed_by,
                 'at', to_char(reviewed_at at time zone 'Africa/Cairo','HH24:MI'),
                 'paid', rv_paid, 'channel', rv_channel, 'note', rv_note, 'src', rv_src) end,
        'date', to_char(actual_date,'YYYY-MM-DD'),
        'time', to_char(actual_date,'HH24:MI'),
        'kind', 'فيزا', 'channel', channel, 'visa_no', visa_no, 'visa_name', visa_name, 'bill_no', sth_id,
        'paid', paid_val, 'manual', manual,
        'party', coalesce(to_name, from_name),
        'from', from_name, 'to', to_name,
        'cust_name', cust_name, 'cust_code', cust_code,
        'user_name', user_name, 'amount', amount,
        'computer', computer, 'notes', notes, 'is_sarf', false,
        'state', state, 'evidence', ev, 'suggest', sugg_t
      ) order by ord), '[]'::jsonb)
      from (select *, row_number() over (order by actual_date desc, fh_id desc) ord
              from f order by actual_date desc, fh_id desc
             limit v_lim offset v_off) p)
  ) into v_out;
  return v_out;
end $function$;

comment on function public.get_card_review(text, date, date, text, integer, integer)
  is 'مراجعة تحصيل البطاقات. p_state: matched|unexplained|feed_gap|no_feed|pending|unpaid (unpaid = كل اللي لم يصرف أي reviewed_by is null بغض النظر عن حالة المطابقة)';
