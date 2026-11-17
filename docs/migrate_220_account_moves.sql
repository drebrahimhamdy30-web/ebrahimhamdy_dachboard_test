/* ════════════════════════════════════════════════════════════════
   دفتر حركات الحسابات — شاشة واحدة لكل الفروع (2026-11-17)
   ----------------------------------------------------------------
   **السؤال اللي بدأ ده (المالك)**: شاشة «مراجعة تحصيل بطاقات
   الائتمان» بتعرض **الفاتورة اتحفظت فين**. لكن الفلوس بتتحرك أكتر
   من كده: الفاتورة تتحفظ فيزا على نقطة البيع بـ٣٠٠ ج، وبعدين
   **تتصرف** من نقطة البيع لحساب باي موب أو المحفظة. الحركتين
   الاتنين حركات على حسابات، ولازم كل واحدة فيهم يبقى ليها مقابل
   في الماكينة/المحفظة بتاعتها.
   فالمطلوب: **دفتر حركات** لكل حساب، أيًا كان نوع الحركة.

   ── المصدر ─────────────────────────────────────────────────────
   `cashier_transactions` = مرآة `F_Transaction_Header` بتاعة eplus،
   و**فيها كل الحركات مش الفيزا بس** (اتأكد: ٨٣٢١ فاتورة نقدي +
   ١٣٧٧ بطاقة + ٥٧٩ تحويل + ٩٥٠ مورد/مصروف/قيد في ٧ أيام).
   و`eplus_safes` فيها الحسابات بأسمائها وأنواعها.

   ── الفكرة: كل معاملة تتفكّ لرِجلين ───────────────────────────
   أي صف فيه طرفين: `from` و`to`. لو الطرف نوعه **٣** يبقى حساب.
     • `to_type=3`   → فلوس **داخلة** حساب to_id
     • `from_type=3` → فلوس **خارجة** من حساب from_id
   والتحويل (٣→٣) بيطلّع **رِجلين**: صرف من نقطة البيع ودخول في
   المحفظة. وده مقصود — ده بالظبط اللي المالك عايز يشوف له مقابل.
   ⚠️ يعني مجموع «داخل» + «خارج» مش رقم واحد؛ العمودين منفصلين.

   ── أنواع الأطراف في eplus (اتقروا من البيانات) ───────────────
     ١ عميل · ٢ مورد · ٣ حساب/خزنة · ٤ حساب عام · ٥ بند مصروف
     ٨ عميل (بطاقة) · ١٠ حساب دفتري (إيرادات/النقدية/الشيكات)

   ⚠️ **الوقت**: `actual_date` نوعه `timestamp without time zone`
      ومتخزّن **بتوقيت القاهرة حرفيًا** (زي ما eplus كتبه). فالمقارنة
      بحدود اليوم بتتم على الـnaive مباشرة — **مش** بـ`at time zone`،
      عشان تفضل sargable وماتعتمدش على `TimeZone` بتاع الجلسة
      (PostgREST بيشتغل UTC، فالتحويل كان هيزحلق اليوم ساعتين).

   ⚠️ **fcs_id مش fcs_code**: الربط بـ`eplus_safes.fcs_id` (الداخلي).
      الكود المعروض في eplus رقم تاني خالص.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── فهرس للمدى الزمني (الموجود كان بالكاشير فمابيخدمش المدى) ── */
create index if not exists ix_cashtxn_br_date
  on public.cashier_transactions (branch, actual_date desc);

/* ── الحارس: صلاحية الصفحة ──────────────────────────────────── */
create or replace function public.account_moves_can_use()
returns boolean language sql stable security definer set search_path = public
as $fn$
  select coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') = 'service_role'
      or public.jwt_app_role() = 'admin'
      or exists (select 1 from page_permissions p
                  where p.page_key = 'account_moves'
                    and p.role = public.jwt_app_role()
                    and p.can_view);
$fn$;

revoke all on function public.account_moves_can_use() from public, anon;
grant execute on function public.account_moves_can_use() to authenticated;

/* ── الدالة الرئيسية ─────────────────────────────────────────── */
create or replace function public.get_account_moves(
  p_branch     text default null,   -- كود الفرع، null = الكل (حسب الصلاحية)
  p_account    int  default null,   -- fcs_id
  p_acct_type  int  default null,   -- 1 نقاط بيع · 2 خزن · 3 محافظ وماكينات
  p_from       date default null,
  p_to         date default null,
  p_dir        text default null,   -- in | out
  p_kind       text default null,
  p_q          text default null,
  p_limit      int  default 50,
  p_offset     int  default 0
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
       and c.actual_date >= v_from::timestamp
       and c.actual_date <  (v_to + 1)::timestamp
  ),
  /* كل معاملة تتفكّ لرِجل داخلة ورِجل خارجة (التحويل بيطلّع الاتنين) */
  legs as (
    select b.*, 'in'::text as dir, b.to_id as acct_id, b.to_name as acct_name_raw,
           b.from_type as opp_type, b.from_id as opp_id, b.from_name as opp_name
      from base b where b.to_type = 3
    union all
    select b.*, 'out'::text, b.from_id, b.from_name,
           b.to_type, b.to_id, b.to_name
      from base b where b.from_type = 3
  ),
  k as (
    select l.*,
           s.name_ar  as acct_name_db,
           s.fcs_code as acct_code,
           s.fcs_type as acct_type,
           s.active   as acct_active,
           case
             when l.is_visa = 1                                  then 'bill_card'
             when l.tt2 = 1 and l.from_type = 1                  then 'bill_cash'
             when l.tt2 = 1 and l.from_type = 2                  then 'from_supplier'
             when l.from_type = 3 and l.to_type = 3              then 'transfer'
             when l.tt2 = 2 and l.to_type = 1                    then 'to_customer'
             when l.tt2 = 2 and l.to_type = 2                    then 'to_supplier'
             when l.tt2 = 2 and l.to_type = 5                    then 'expense'
             when l.from_type in (4,10) or l.to_type in (4,10)   then 'ledger'
             else 'other'
           end as kind
      from legs l
      left join eplus_safes s on s.branch = l.branch and s.fcs_id = l.acct_id
  ),
  /* fa = كل الفلاتر ما عدا الحساب نفسه — عشان شريط الحسابات يفضل
     كامل وانت واقف على حساب واحد */
  fa as (
    select * from k
     where (p_acct_type is null or acct_type = p_acct_type)
       and (p_dir  is null or dir  = p_dir)
       and (p_kind is null or kind = p_kind)
       and (v_q is null or (
             coalesce(opp_name,'')     ilike '%'||v_q||'%' or
             coalesce(cust_name,'')    ilike '%'||v_q||'%' or
             coalesce(cust_code,'')    ilike '%'||v_q||'%' or
             coalesce(notes,'')        ilike '%'||v_q||'%' or
             coalesce(user_name,'')    ilike '%'||v_q||'%' or
             coalesce(computer,'')     ilike '%'||v_q||'%' or
             coalesce(visa_no,'')      ilike '%'||v_q||'%' or
             coalesce(acct_name_db, acct_name_raw, '') ilike '%'||v_q||'%' or
             fh_id::text = v_q or coalesce(sth_id,0)::text = v_q or
             round(amount)::text = v_q))
  ),
  f as (
    select * from fa where (p_account is null or acct_id = p_account)
  ),
  pgrows as (
    select * from f order by actual_date desc, fh_id desc, dir limit v_lim offset v_off
  ),
  rows_j as (
    select jsonb_agg(jsonb_build_object(
             'branch',      p.branch,
             'fh_id',       p.fh_id,
             'dt',          to_char(p.actual_date,'YYYY-MM-DD HH24:MI:SS'),
             'dir',         p.dir,
             'amount',      p.amount,
             'kind',        p.kind,
             'acct_id',     p.acct_id,
             'acct_name',   coalesce(p.acct_name_db, p.acct_name_raw, p.acct_id::text),
             'acct_code',   p.acct_code,
             'acct_type',   p.acct_type,
             'acct_active', p.acct_active,
             'opp_type',    p.opp_type,
             'opp_id',      p.opp_id,
             'opp_name',    p.opp_name,
             'cust_name',   p.cust_name,
             'cust_code',   p.cust_code,
             'party_name',  p.party_name,
             'sth_id',      p.sth_id,
             'is_visa',     p.is_visa,
             'channel',     p.channel,
             'visa_no',     p.visa_no,
             'visa_name',   p.visa_name,
             'visa_value',  p.visa_value,
             'user_name',   p.user_name,
             'computer',    p.computer,
             'cashier_id',  p.cashier_id,
             'notes',       p.notes,
             'tt2',         p.tt2,
             'form_type',   p.form_type,
             'cp_type',     p.cp_type,
             'synced_at',   p.synced_at,
             /* إثراء: مراجعة الشيفت + صورة التحويل + حالة الصرف الآلي */
             'rv', case when r.reviewed_by is null then null else jsonb_build_object(
                     'by', r.reviewed_by, 'at', r.reviewed_at, 'paid', r.paid, 'note', r.note) end,
             'receipts', (select count(*) from txn_receipts t
                           where t.branch = p.branch and t.kind = 'card' and t.ref_id = p.fh_id::text),
             /* المعاملة دي اتطلب صرفها */
             'disb', case when q1.id is null then null else jsonb_build_object(
                     'status', q1.status, 'to', q1.resolved_to_name, 'paid', q1.paid,
                     'eplus_fh', q1.eplus_fh_id, 'error', q1.error, 'at', q1.processed_at) end,
             /* الحركة دي **هي** صرف آلي لمعاملة تانية */
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
    'total',    (select count(*) from f),
    'sum_in',   (select coalesce(sum(amount),0) from f where dir = 'in'),
    'sum_out',  (select coalesce(sum(amount),0) from f where dir = 'out'),
    'from',     v_from, 'to', v_to, 'limit', v_lim, 'offset', v_off,
    'branches', (select coalesce(jsonb_agg(distinct branch),'[]'::jsonb) from fa),
    'kinds',    (select coalesce(jsonb_object_agg(kind, n),'{}'::jsonb)
                   from (select kind, count(*) n from fa group by kind) z),
    'accounts', (select coalesce(jsonb_agg(x order by x->>'branch', (x->>'name')),'[]'::jsonb) from (
                   select jsonb_build_object(
                     'branch', branch, 'acct_id', acct_id,
                     'name',   coalesce(acct_name_db, acct_name_raw, acct_id::text),
                     'code',   acct_code, 'type', acct_type, 'active', acct_active,
                     'n',      count(*),
                     'in',     coalesce(sum(amount) filter (where dir = 'in'), 0),
                     'out',    coalesce(sum(amount) filter (where dir = 'out'), 0)) x
                     from fa
                    group by branch, acct_id, acct_name_db, acct_name_raw, acct_code, acct_type, acct_active
                 ) t),
    'rows',     (select coalesce(j,'[]'::jsonb) from rows_j)
  ) into v_out;

  return v_out;
end;
$fn$;

revoke all on function public.get_account_moves(text,int,int,date,date,text,text,text,int,int) from public, anon;
grant execute on function public.get_account_moves(text,int,int,date,date,text,text,text,int,int) to authenticated;

/* ── تسجيل الصفحة + صلاحيتها ─────────────────────────────────── */
insert into app_pages (key, file, title, section, sort_order, is_active)
values ('account_moves', 'account_moves.html', 'حركات الحسابات', 'الحسابات والخزينة', 636, true)
on conflict (key) do update
   set file = excluded.file, title = excluded.title,
       section = excluded.section, sort_order = excluded.sort_order, is_active = true;

/* الأدمن يشوف كل الفروع؛ باقي الأدوار بـfalse والمالك يفتح اللي عايزه
   من شاشة الصلاحيات (نفس أسلوب pos_balances) */
insert into page_permissions (role, page, page_key, can_view, can_edit, all_branches)
select r.role, 'account_moves.html', 'account_moves',
       r.role = 'admin', false, r.role = 'admin'
  from (select distinct role from page_permissions) r
on conflict do nothing;
