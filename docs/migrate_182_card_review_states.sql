/* ════════════════════════════════════════════════════════════════
   تصنيف تلقائي لحركات البطاقات + تبويب «الفيزا والمحافظ» (2026-10-31)
   ----------------------------------------------------------------
   **السؤال اللي بدأ ده**: «المحاسب لو قال تم على المعاملة، إيه اللي
   يأكد إنه راجع صح؟» — والإجابة كانت **ولا حاجة**. زر «تم» بيسجّل
   إن حد ضغط، مش إن الفلوس وصلت. فالنظام بقى يراجع بنفسه ويقول
   **الدليل**، والمحاسب يبص على اللي محتاج بص بس.

   ── أربع حالات (وليه أربعة مش اتنين) ──────────────────────────
   «مطابَق» و«بلا تفسير» لوحدهم كذب: لو كشف المصدر نفسه ناقص،
   المعاملة السليمة هتتّهم. فالحالات:
     🟢 matched      لقينا الحركة في كشف المصدر
     🔴 unexplained  الكشف موجود وشغّال في وقتها ومفيهاش
     ⚪ feed_gap     الكشف نفسه ناقص في الفترة دي — مانعرفش
     🟡 no_feed      القناة مالهاش كشف أصلًا (فوري/انستاباي)

   🔑 **«الكشف ناقص» مقياس مش تخمين**: `wallet_sms.balance` رصيد
   تراكمي حقيقي لكل محفظة — اتأكد على عيّنة: 31,778.47 + 207 =
   31,985.47 + 100 = 32,085.47 … بالمليم. فلو القفزة بين رسالتين
   متتاليتين ≠ قيمة الرسالة، يبقى فيه رسايل ضاعت بينهم، **وبنعرف
   قيمتها بالظبط**. القياس على ١٤ يوم: ١٠٩٨ زوج، ١٠١١ متصل (٩٢٪)،
   و**٨٧ فجوة بقيمة ٢٣٦٬٦٢٨ ج** رسايلها ماوصلتش.
   (المالك نبّه من الأول إن مزامنة رسايل المحافظ بتسقط أحيانًا —
    ده تحويل تنبيهه لمقياس.)

   ⚠️ **الفروع متكتبة عربي في المصادر وبإملاءين**: `wallet` بتكتب
      «سيدي بشر» بالياء و`wallet_sms` «سيدى بشر» بالألف المقصورة،
      و`cashier_transactions` بتستعمل الكود الإنجليزي. كله بيعدّي
      على `branch_code_of()` اللي بتطبّع ي/ى.

   ⚠️ **المطابقة واحد لواحد**: الربط بالترتيب الزمني جوّه كل
      (فرع + قيمة) — من غير كده حركة واحدة في الكشف كانت هتبرّر
      كذا معاملة بنفس المبلغ وتدّي اطمئنان كاذب.

   ⚠️ دالة **جديدة** مش تعديل على `get_card_txns` — القديمة بتفضل
      زي ما هي لحد ما الشاشة تستقر على الجديدة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── فجوات كشف المحافظ: فين الرسايل اللي ضاعت ────────────────── */
create or replace function public.wallet_sms_gaps(p_from date, p_to date)
returns table (branch_code text, wal text, gap_from timestamptz, gap_to timestamptz, gap_value numeric)
language sql stable security definer set search_path = public
as $fn$
  with m as (
    select public.branch_code_of(branch) as bc, to_no as wal, "createdAt" as ts, balance,
           case when type = 'استلام' then ammount else -ammount end - coalesce(fees,0) as delta
      from wallet_sms
     where balance is not null and coalesce(to_no,'') <> ''
       and ("createdAt" at time zone 'Africa/Cairo')::date between p_from - 1 and p_to + 1
  ),
  d as (
    select m.*, lag(balance) over w as prev_bal, lag(ts) over w as prev_ts
      from m window w as (partition by wal order by ts, balance)
  )
  select bc, wal, prev_ts, ts, round(abs(balance - (prev_bal + delta)), 2)
    from d
   where prev_bal is not null
     and abs(balance - (prev_bal + delta)) > 0.02;
$fn$;

revoke all on function public.wallet_sms_gaps(date, date) from public, anon;
grant execute on function public.wallet_sms_gaps(date, date) to authenticated;

/* ── التبويب الأول: حركات البطاقات مصنَّفة ───────────────────── */
create or replace function public.get_card_review(
  p_branch       text    default null,
  p_from         date    default null,
  p_to           date    default null,
  p_state        text    default null,    -- matched|unexplained|feed_gap|no_feed|pending
  p_limit        int     default 50,
  p_offset       int     default 0
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_from date; v_to date; v_lim int; v_off int; v_br text; v_role text; v_all boolean;
  v_out jsonb;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  /* نطاق الفرع على السيرفر — إخفاء الفلتر في الشاشة مش حماية */
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
  /* المعاملات: نفس منطق get_card_txns بالحرف (القيمة المكتوبة لها
     الأولوية لأن الموظف بيكتب المبلغ المحوَّل في خانة الرقم) */
  t as (
    select c.branch, c.fh_id, c.actual_date, c.amount, c.channel, c.visa_no,
           c.user_name, c.computer, c.notes, c.from_name, c.to_name,
           (c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1) as manual,
           case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then c.visa_no::numeric else c.amount end as paid_val,
           r.reviewed_by, r.reviewed_at, r.paid as rv_paid, r.channel as rv_channel,
           case when c.channel ~* '^paymob'                   then 'machine'
                when c.channel ~* 'vodaf|orange|wee|etisalat' then 'sms'
                else 'none' end as feed
      from cashier_transactions c
      left join shift_txn_reviews r on r.branch = c.branch and r.fh_id = c.fh_id
     where coalesce(c.is_visa,0) = 1
       and (c.actual_date at time zone 'Africa/Cairo')::date between v_from and v_to
       and (v_br is null or c.branch = v_br)
  ),
  /* كشوف المصدر في نفس النافذة (+يوم من كل ناحية للحركات الحدودية) */
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
  /* ربط واحد لواحد: الترتيب الزمني جوّه كل (فرع + قيمة) */
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
  j as (
    select t.*,
           h.ev,
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
  ),
  f as (
    select * from j
     where p_state is null
        or (p_state = 'pending' and state in ('unexplained','feed_gap') and reviewed_by is null)
        or state = p_state
  )
  select jsonb_build_object(
    'total',         (select count(*) from f),
    'total_paid',    (select coalesce(sum(paid_val),0) from f),
    'reviewed',      (select count(*) from f where reviewed_by is not null),
    'reviewed_paid', (select coalesce(sum(coalesce(rv_paid, paid_val)),0) from f where reviewed_by is not null),
    'pending',       (select count(*) from f where reviewed_by is null),
    'pending_paid',  (select coalesce(sum(paid_val),0) from f where reviewed_by is null),
    'states', (select coalesce(jsonb_object_agg(state, jsonb_build_array(n, v)), '{}'::jsonb)
                 from (select state, count(*) n, round(sum(paid_val)) v from j group by state) q),
    'branches', (select coalesce(jsonb_agg(distinct branch),'[]'::jsonb) from f),
    'channels', (select coalesce(jsonb_agg(distinct coalesce(channel,'—')),'[]'::jsonb) from f),
    'users',    (select coalesce(jsonb_agg(distinct user_name) filter (where user_name is not null),'[]'::jsonb) from f),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                'branch', branch, 'fh_id', fh_id, 'actual_date', actual_date,
                'amount', amount, 'paid', paid_val, 'manual', manual,
                'channel', coalesce(rv_channel, channel), 'visa_no', visa_no,
                'user_name', user_name, 'computer', computer, 'notes', notes,
                'from_name', from_name, 'to_name', to_name,
                'state', state, 'evidence', ev,
                'rv', case when reviewed_by is null then null else jsonb_build_object(
                        'by', reviewed_by, 'at', reviewed_at, 'paid', rv_paid, 'channel', rv_channel) end)
              order by actual_date desc, fh_id desc), '[]'::jsonb)
            from (select * from f order by actual_date desc, fh_id desc
                   limit v_lim offset v_off) p)
  ) into v_out;
  return v_out;
end $fn$;

revoke all on function public.get_card_review(text, date, date, text, int, int) from public, anon;
grant execute on function public.get_card_review(text, date, date, text, int, int) to authenticated;

/* ════════════════════════════════════════════════════════════════
   تعديلات لاحقة على get_card_review (اتطبّقت بالترتيب ده)
   ════════════════════════════════════════════════════════════════ */

/* (أ) «محتاج مراجعة» = بلا تفسير وغير مُراجَع فقط.
   «المصدر ناقص» مش داخلة: المحاسب مايقدرش يعمل فيها حاجة، ولو
   حطّيناها الشريحة تبقى ضوضاء وأول حاجة حقيقية تعدّي. */
do $do$
declare src text; nsrc text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_card_review';
  nsrc := replace(src,
    $old$(p_state = 'pending' and state in ('unexplained','feed_gap') and reviewed_by is null)$old$,
    $new$(p_state = 'pending' and state = 'unexplained' and reviewed_by is null)$new$);
  if nsrc <> src then execute nsrc; end if;
end $do$;

/* (ب) عدّاد «محتاج مراجعة» لازم يفضل ثابت مهما كانت الشريحة
   المختارة، وإلا الشريحة بتقول عدد الشريحة الحالية بدل المتبقّي. */
do $do$
declare src text; nsrc text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_card_review';
  if src like '%needs_review%' then return; end if;
  nsrc := replace(src, $old$    'states', (select$old$,
    $new$    'needs_review', (select count(*) from j where state = 'unexplained' and reviewed_by is null),
    'needs_review_val', (select coalesce(round(sum(paid_val)),0) from j where state = 'unexplained' and reviewed_by is null),
    'states', (select$new$);
  if nsrc = src then raise exception 'مالقيتش مفتاح states'; end if;
  execute nsrc;
end $do$;

/* (ج) شكل الصفوف **نفس get_card_txns بالحرف** + state/evidence —
   الجدول في الشاشة بيرسمها من غير أي تعديل (طلب المالك: احتفظ
   بنفس الشكل والتكوين وضيف عليه الأعمدة الجديدة). */
do $do$
declare src text; nsrc text; a int; b int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_card_review';
  if src like '%''is_sarf'', false%' then return; end if;
  a := position($m$    'rows', (select coalesce(jsonb_agg(jsonb_build_object($m$ in src);
  b := position($m$  ) into v_out;$m$ in src);
  if a = 0 or b = 0 then raise exception 'مالقيتش بلوك rows'; end if;
  nsrc := substring(src from 1 for a - 1)
    || $m$    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'fh_id', fh_id, 'branch', branch,
        'rv', case when reviewed_by is null then null else jsonb_build_object(
                 'by', reviewed_by,
                 'at', to_char(reviewed_at at time zone 'Africa/Cairo','HH24:MI'),
                 'paid', rv_paid, 'channel', rv_channel) end,
        'date', to_char(actual_date,'YYYY-MM-DD'),
        'time', to_char(actual_date,'HH24:MI'),
        'kind', 'فيزا', 'channel', channel, 'visa_no', visa_no,
        'paid', paid_val, 'manual', manual,
        'party', coalesce(to_name, from_name),
        'from', from_name, 'to', to_name,
        'user_name', user_name, 'amount', amount,
        'computer', computer, 'notes', notes, 'is_sarf', false,
        'state', state, 'evidence', ev
      ) order by ord), '[]'::jsonb)
      from (select *, row_number() over (order by actual_date desc, fh_id desc) ord
              from f order by actual_date desc, fh_id desc
             limit v_lim offset v_off) p)
$m$ || substring(src from b);
  execute nsrc;
end $do$;
