/* ════════════════════════════════════════════════════════════════
   حركات الحسابات: قصر الشاشة على الحسابات البنكية فقط
   (2026-11-17، تعديل على migrate_220)
   ----------------------------------------------------------------
   **طلب المالك**: «الشاشة تقتصر على الحسابات البنكية فقط» —
   يعني `eplus_safes.fcs_type = 3` (نفس شاشة «حسابات بنكية» في
   eplus: المحافظ والماكينات وفوري وانستاباي). مش نقاط البيع
   ولا الخزن.

   و**المقصود اللي اتحفظ فعلًا على الحساب البنكي** — المالك رفض
   صراحةً إني أنسب الفواتير لحساباتها بالقناة: «لا متنسبش، انا
   محتاج فعلا اللى اتحفظ على الحسابات البنكيه». فالشاشة بتعرض
   رِجل الفلوس الحقيقية بس، من غير أي استنتاج.

   ── نتيجة متوقعة لازم تتقال ────────────────────────────────────
   في ٧ أيام: المعمورة ٤٠١ حركة · السيوف ١٠ · **سان صفر · بشر صفر**.
   ده مش عطل في الشاشة: في سان وبشر الفاتورة بتتقفل على «نقطة بيع 1»
   وعمرها ما بتتحرك للحساب البنكي، لأن الصرف لسه مش مفعّل هناك.
   الشاشة بتقول الحقيقة دي بدل ما تغطّيها.

   ⚠️ **مابنلمسش `wallet_channel_map`** — الجدول ده بيقرر الفلوس
      بتتصرف لفين فعليًا (enqueue_wallet_disbursement)، وملوش علاقة
      بالعرض.

   مافيش جداول جديدة: المصدر `cashier_transactions` + `eplus_safes`
   اللي موجودين ومتزامنين أصلًا.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* التوقيع اتغيّر (اتشال p_acct_type — الشاشة بقت بنكية بالكامل) */
drop function if exists public.get_account_moves(text,int,int,date,date,text,text,text,int,int);

create or replace function public.get_account_moves(
  p_branch   text default null,   -- كود الفرع، null = الكل (حسب الصلاحية)
  p_account  int  default null,   -- fcs_id للحساب البنكي
  p_from     date default null,
  p_to       date default null,
  p_dir      text default null,   -- in | out
  p_kind     text default null,
  p_q        text default null,
  p_limit    int  default 50,
  p_offset   int  default 0
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_from date; v_to date; v_lim int; v_off int;
  v_br text; v_role text; v_all boolean; v_q text; v_out jsonb;
begin
  if not public.account_moves_can_use() then
    raise exception 'غير مصرّح بعرض حركات الحسابات' using errcode = '42501';
  end if;

  /* نطاق الفرع على السيرفر — إخفاء الفلتر في الشاشة مش حماية */
  v_role := public.jwt_app_role();
  if coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') = 'service_role'
     or v_role = 'admin' then
    v_br := nullif(btrim(coalesce(p_branch,'')),'');
  else
    select pp.all_branches into v_all from page_permissions pp
     where pp.role = v_role and pp.page_key = 'account_moves';
    if coalesce(v_all,false) then v_br := nullif(btrim(coalesce(p_branch,'')),'');
    else v_br := coalesce(public.branch_code_of(public.jwt_branch()), '__none__'); end if;
  end if;

  v_from := coalesce(p_from, (now() at time zone 'Africa/Cairo')::date);
  v_to   := coalesce(p_to,   (now() at time zone 'Africa/Cairo')::date);
  v_lim  := greatest(1, least(coalesce(p_limit, 50), 200));
  v_off  := greatest(0, coalesce(p_offset, 0));
  v_q    := nullif(btrim(coalesce(p_q,'')),'');

  with base as (
    select c.branch, c.fh_id, c.actual_date, c.amount, c.tt2, c.form_type, c.cp_type,
           c.is_visa, c.channel, c.visa_no, c.visa_name, c.visa_value,
           c.from_type, c.from_id, c.from_name, c.to_type, c.to_id, c.to_name,
           c.cust_name, c.cust_code, c.party_name, c.sth_id,
           c.user_name, c.computer, c.cashier_id, c.notes, c.synced_at
      from cashier_transactions c
     where (v_br is null or c.branch = v_br)
       -- actual_date وقت قاهرة حرفي: المقارنة على الـnaive مباشرة
       and c.actual_date >= v_from::timestamp
       and c.actual_date <  (v_to + 1)::timestamp
  ),
  bank as (select branch, fcs_id, name_ar, fcs_code, active
             from eplus_safes where fcs_type = 3),
  /* كل معاملة تتفكّ لرِجلين: داخلة حساب وخارجة من حساب */
  legs as (
    select b.*, 'in'::text as dir, b.to_id as acct_id,
           b.from_type as opp_type, b.from_id as opp_id, b.from_name as opp_name
      from base b where b.to_type = 3
    union all
    select b.*, 'out'::text, b.from_id,
           b.to_type, b.to_id, b.to_name
      from base b where b.from_type = 3
  ),
  k as (
    select l.*, n.name_ar as acct_name, n.fcs_code as acct_code, n.active as acct_active,
           case
             when l.is_visa = 1                                then 'bill_card'
             when l.tt2 = 1 and l.from_type = 1                then 'bill_cash'
             when l.tt2 = 1 and l.from_type = 2                then 'from_supplier'
             when l.from_type = 3 and l.to_type = 3            then 'transfer'
             when l.tt2 = 2 and l.to_type = 1                  then 'to_customer'
             when l.tt2 = 2 and l.to_type = 2                  then 'to_supplier'
             when l.tt2 = 2 and l.to_type = 5                  then 'expense'
             when l.from_type in (4,10) or l.to_type in (4,10) then 'ledger'
             else 'other'
           end as kind
      from legs l
      join bank n on n.branch = l.branch and n.fcs_id = l.acct_id   -- بنكية فقط
  ),
  fa as (
    select * from k
     where (p_dir  is null or dir  = p_dir)
       and (p_kind is null or kind = p_kind)
       and (v_q is null or (
             coalesce(opp_name,'')  ilike '%'||v_q||'%' or
             coalesce(cust_name,'') ilike '%'||v_q||'%' or
             coalesce(cust_code,'') ilike '%'||v_q||'%' or
             coalesce(notes,'')     ilike '%'||v_q||'%' or
             coalesce(user_name,'') ilike '%'||v_q||'%' or
             coalesce(computer,'')  ilike '%'||v_q||'%' or
             coalesce(visa_no,'')   ilike '%'||v_q||'%' or
             coalesce(channel,'')   ilike '%'||v_q||'%' or
             coalesce(acct_name,'') ilike '%'||v_q||'%' or
             fh_id::text = v_q or coalesce(sth_id,0)::text = v_q or
             round(amount)::text = v_q))
  ),
  f as (select * from fa where (p_account is null or acct_id = p_account)),
  pgrows as (select * from f order by actual_date desc, fh_id desc, dir limit v_lim offset v_off),
  rows_j as (
    select jsonb_agg(jsonb_build_object(
             'branch', p.branch, 'fh_id', p.fh_id,
             'dt', to_char(p.actual_date,'YYYY-MM-DD HH24:MI:SS'),
             'dir', p.dir, 'amount', p.amount, 'kind', p.kind,
             'acct_id', p.acct_id, 'acct_name', p.acct_name,
             'acct_code', p.acct_code, 'acct_active', p.acct_active,
             'opp_type', p.opp_type, 'opp_id', p.opp_id, 'opp_name', p.opp_name,
             'cust_name', p.cust_name, 'cust_code', p.cust_code, 'party_name', p.party_name,
             'sth_id', p.sth_id, 'is_visa', p.is_visa, 'channel', p.channel,
             'visa_no', p.visa_no, 'visa_name', p.visa_name, 'visa_value', p.visa_value,
             'user_name', p.user_name, 'computer', p.computer, 'cashier_id', p.cashier_id,
             'notes', p.notes, 'tt2', p.tt2, 'form_type', p.form_type, 'cp_type', p.cp_type,
             'synced_at', p.synced_at,
             'rv', case when r.reviewed_by is null then null else jsonb_build_object(
                     'by', r.reviewed_by, 'at', r.reviewed_at, 'paid', r.paid, 'note', r.note) end,
             'receipts', (select count(*) from txn_receipts t
                           where t.branch = p.branch and t.kind = 'card' and t.ref_id = p.fh_id::text),
             'disb', case when q1.id is null then null else jsonb_build_object(
                     'status', q1.status, 'to', q1.resolved_to_name, 'paid', q1.paid,
                     'eplus_fh', q1.eplus_fh_id, 'error', q1.error, 'at', q1.processed_at) end,
             'is_auto_disb', case when q2.id is null then null else jsonb_build_object(
                     'src_fh', q2.fh_id, 'bill', q2.bill_no, 'employee', q2.employee,
                     'channel', q2.channel) end
           ) order by p.actual_date desc, p.fh_id desc, p.dir) j
      from pgrows p
      left join shift_txn_reviews        r  on r.branch  = p.branch and r.fh_id = p.fh_id
      left join wallet_disbursement_queue q1 on q1.branch = p.branch and q1.fh_id = p.fh_id
      left join wallet_disbursement_queue q2 on q2.branch = p.branch and q2.eplus_fh_id = p.fh_id
  )
  select jsonb_build_object(
    'total',   (select count(*) from f),
    'sum_in',  (select coalesce(sum(amount),0) from f where dir = 'in'),
    'sum_out', (select coalesce(sum(amount),0) from f where dir = 'out'),
    'from', v_from, 'to', v_to, 'limit', v_lim, 'offset', v_off,
    'kinds', (select coalesce(jsonb_object_agg(kind, n),'{}'::jsonb)
                from (select kind, count(*) n from fa group by kind) z),
    /* كل الحسابات البنكية في النطاق — حتى اللي مالهاش حركة، عشان
       «صفر حركة» تبقى معلومة ظاهرة مش حساب غايب من القايمة */
    'accounts', (select coalesce(jsonb_agg(x order by x->>'branch', (x->>'name')),'[]'::jsonb) from (
                   select jsonb_build_object('branch', n.branch, 'acct_id', n.fcs_id,
                     'name', n.name_ar, 'code', n.fcs_code, 'active', n.active,
                     'n',   count(a.fh_id),
                     'in',  coalesce(sum(a.amount) filter (where a.dir = 'in'), 0),
                     'out', coalesce(sum(a.amount) filter (where a.dir = 'out'), 0)) x
                     from bank n
                     left join fa a on a.branch = n.branch and a.acct_id = n.fcs_id
                    where (v_br is null or n.branch = v_br)
                    group by n.branch, n.fcs_id, n.name_ar, n.fcs_code, n.active
                 ) t),
    'rows', (select coalesce(j,'[]'::jsonb) from rows_j)
  ) into v_out;

  return v_out;
end;
$fn$;

revoke all on function public.get_account_moves(text,int,date,date,text,text,text,int,int) from public, anon;
grant execute on function public.get_account_moves(text,int,date,date,text,text,text,int,int) to authenticated;

notify pgrst, 'reload schema';
