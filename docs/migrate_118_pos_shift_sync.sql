/* ═══════════════════════════════════════════════════════════════════
   تفاصيل الشيفت الحالي — مزامنة التقفيلات وحركات نقاط البيع من eplus
   ───────────────────────────────────────────────────────────────────
   جدولين + وظيفتين في مركز المزامنة (المحرّك يلتقطها تلقائيًا لكل فرع).
   • shift_changes      = تقفيلات الشيفت لكل نقطة؛ بداية الفترة = sc_curr_cash آخر تقفيل.
   • cashier_transactions = حركات الخزينة؛ **النسب بالحساب (الدرج في from/to type=3)**
     زي تقرير «حركة حساب تفصيلي» في eplus — مش بالكاشير الفعلي
     (الفيزا كلها متسمّعة على حساب نقطة البيع مهما كان الكاشير اللي حصّلها).
   كل العربي بيوصل سليم (المحرّك .NET SqlConnection يدعم Unicode).
   يتطبّق على: السحابة (حيث تكتب المزامنة) + الذاتي (للشاشة والدوال).
   ═══════════════════════════════════════════════════════════════════ */

/* ── الجداول ── */
create table if not exists public.shift_changes (
  branch text not null, sc_id bigint not null, cashier_id int, point_name text,
  shift_start timestamp, start_cash numeric, curr_cash numeric, act_cash numeric,
  closed_at timestamp, to_emp numeric, visa_count int, synced_at timestamptz default now(),
  primary key (branch, sc_id)
);
create index if not exists ix_shift_changes_br_closed on public.shift_changes(branch, closed_at desc);
alter table public.shift_changes enable row level security;
grant all on public.shift_changes to service_role;

create table if not exists public.cashier_transactions (
  branch text not null, fh_id bigint not null, actual_date timestamp, tt2 int, amount numeric, computer text,
  from_type int, from_id bigint, from_name text,
  to_type int, to_id bigint, to_name text,
  user_name text, is_visa int, channel text, visa_value numeric, notes text,
  synced_at timestamptz default now(),
  primary key (branch, fh_id)
);
-- أعمدة من النسخة الأولى (تُهمَل؛ النسب بقى بالحساب):
alter table public.cashier_transactions add column if not exists from_type int;
alter table public.cashier_transactions add column if not exists from_id bigint;
alter table public.cashier_transactions add column if not exists from_name text;
alter table public.cashier_transactions add column if not exists to_type int;
alter table public.cashier_transactions add column if not exists to_id bigint;
alter table public.cashier_transactions add column if not exists to_name text;
create index if not exists ix_cashtxn_to   on public.cashier_transactions(branch, to_id)   where to_type=3;
create index if not exists ix_cashtxn_from on public.cashier_transactions(branch, from_id) where from_type=3;
alter table public.cashier_transactions enable row level security;
grant all on public.cashier_transactions to service_role;

/* ── وظيفة الشيفتات ── */
insert into public.sync_jobs (id, name, source_db, enabled, interval_minutes, window_days, window_refresh_minutes, sort_order, steps)
values ('shifts','الشيفتات','Genius',true,1,2,5,3,
$json$[{"select":"SELECT '{branch}' AS branch, sc.sc_id, sc.sc_cashier_id AS cashier_id, cs.fcs_name_ar AS point_name, sc.sc_shift_start_time AS shift_start, sc.sc_start_cash AS start_cash, sc.sc_curr_cash AS curr_cash, sc.sc_act_cash AS act_cash, sc.sec_insert_date AS closed_at, sc.sc_to_employee AS to_emp, sc.sc_visa_act_count AS visa_count FROM Shift_Changes sc LEFT JOIN F_Cash_Store cs ON cs.fcs_id = sc.sc_cashier_id","target":"shift_changes","conflict":"branch,sc_id","probe_max":"SELECT MAX(sc_id) FROM Shift_Changes","where_new":"sc.sc_id > {last_pth}","where_window":"sc.sec_insert_date >= '{cut}' OR sc.sec_update_date >= '{cut}'"}]$json$::jsonb)
on conflict (id) do update set name=excluded.name, enabled=excluded.enabled, interval_minutes=excluded.interval_minutes, window_days=excluded.window_days, window_refresh_minutes=excluded.window_refresh_minutes, steps=excluded.steps, sort_order=excluded.sort_order;

/* ── وظيفة حركات نقاط البيع (النسب بالحساب من from/to) ── */
insert into public.sync_jobs (id, name, source_db, enabled, interval_minutes, window_days, window_refresh_minutes, sort_order, steps)
values ('cashier_txns','حركات نقاط البيع','Genius',true,1,1,5,4,
$json$[{"select":"SELECT '{branch}' AS branch, h.fh_id, h.fh_actual_date AS actual_date, h.fh_trans_type2 AS tt2, h.fh_value AS amount, h.fh_computer AS computer, h.fh_from_type AS from_type, h.fh_from_id AS from_id, h.fh_to_type AS to_type, h.fh_to_id AS to_id, COALESCE(cuf.cust_name_ar, vef.ven_name_ar, csf.fcs_name_ar, acf.ac_name_ar) AS from_name, COALESCE(cut.cust_name_ar, vet.ven_name_ar, cst.fcs_name_ar, act.ac_name_ar) AS to_name, e.e_Name AS user_name, CASE WHEN sv.svi_id IS NOT NULL THEN 1 ELSE 0 END AS is_visa, bk.bnk_name_ar AS channel, sv.visa_value AS visa_value, h.fh_notes AS notes FROM F_Transaction_Header h LEFT JOIN sales_visa_info sv ON sv.fh_id=h.fh_id LEFT JOIN Bank bk ON bk.bnk_id=sv.visa_bank_id LEFT JOIN Customer cuf ON cuf.cust_id=h.fh_from_id AND h.fh_from_type IN (1,8) LEFT JOIN Vendor vef ON vef.ven_id=h.fh_from_id AND h.fh_from_type=2 LEFT JOIN F_Cash_Store csf ON csf.fcs_id=h.fh_from_id AND h.fh_from_type=3 LEFT JOIN F_Account_Chart acf ON acf.ac_id=h.fh_from_id AND h.fh_from_type NOT IN (1,2,3,8) LEFT JOIN Customer cut ON cut.cust_id=h.fh_to_id AND h.fh_to_type IN (1,8) LEFT JOIN Vendor vet ON vet.ven_id=h.fh_to_id AND h.fh_to_type=2 LEFT JOIN F_Cash_Store cst ON cst.fcs_id=h.fh_to_id AND h.fh_to_type=3 LEFT JOIN F_Account_Chart act ON act.ac_id=h.fh_to_id AND h.fh_to_type NOT IN (1,2,3,8) LEFT JOIN Employee e ON e.e_id=(CASE WHEN ISNUMERIC(h.sec_insert_uid)=1 THEN CAST(h.sec_insert_uid AS int) ELSE NULL END)","target":"cashier_transactions","conflict":"branch,fh_id","probe_max":"SELECT MAX(fh_id) FROM F_Transaction_Header","where_new":"h.fh_id > {last_pth}","where_window":"h.sec_insert_date >= '{cut}' OR h.sec_update_date >= '{cut}'"}]$json$::jsonb)
on conflict (id) do update set name=excluded.name, enabled=excluded.enabled, interval_minutes=excluded.interval_minutes, window_days=excluded.window_days, window_refresh_minutes=excluded.window_refresh_minutes, steps=excluded.steps, sort_order=excluded.sort_order;

/* ── حالة الفروع ── */
insert into public.sync_branch_state (job_id, branch, enabled, last_pth)
select j, b, true, 0
from (values ('shifts'),('cashier_txns')) x(j)
cross join (values ('mamora'),('san'),('bishr'),('seyouf')) y(b)
where not exists (select 1 from public.sync_branch_state s where s.job_id = x.j and s.branch = y.b);

/* ═══════════════ دوال الشاشة ═══════════════ */
create or replace function public.get_shift_points(p_branch text)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object('cashier_id',cashier_id,'point_name',coalesce(point_name,'كاشير '||cashier_id)) order by cashier_id),'[]'::jsonb)
  from (select distinct on (cashier_id) cashier_id, point_name
        from shift_changes where branch=p_branch and cashier_id is not null
        order by cashier_id, closed_at desc) z;
$fn$;
grant execute on function public.get_shift_points(text) to anon, authenticated;

-- الشيفت الحالي: النسب بالحساب (to/from = الدرج). الكاش المطلوب = بداية + كاش + توريد − صرف (الفيزا متخصومة).
create or replace function public.get_current_shift(p_branch text, p_cashier int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_close timestamp; v_open numeric; v_pt text; v_out jsonb;
begin
  select closed_at, curr_cash, point_name into v_close, v_open, v_pt
  from shift_changes where branch=p_branch and cashier_id=p_cashier order by closed_at desc limit 1;
  v_open := coalesce(v_open,0);
  with t as (
    select actual_date, amount, is_visa, channel, visa_value, user_name, computer, notes,
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
end$fn$;
grant execute on function public.get_current_shift(text,int) to anon, authenticated;

/* ── التسجيل في قسم الحسابات + صلاحيات العرض ── */
insert into public.app_pages (key, file, title, section, sort_order, is_active)
values ('current_shift','current_shift.html','تفاصيل الشيفت الحالي','الحسابات والخزينة',637,true)
on conflict (key) do update set file=excluded.file, title=excluded.title, section=excluded.section, sort_order=excluded.sort_order, is_active=true;

insert into public.page_permissions (role, page, can_view, can_edit)
select r, 'current_shift.html', true, false
from unnest(array['accountant','admin','cashier','employee','inventory','manager','pharmacist','reviewer','supervisor']) r
on conflict (role, page) do update set can_view=true;

notify pgrst,'reload schema';
