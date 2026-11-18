/* migrate_224 — زرار «راجعتها» بملاحظة على المعاملات غير المطابقة

   طلب المالك 2026-11-19: شاشة مراجعة تحصيل البطاقات يبقى فيها زرار
   إضافي يأكّد على المعاملة غير المطابقة ويكتب عليها ملاحظة.

   ليه جدول منفصل مش shift_txn_reviews: الجدول ده إقرار **الصيدلي**
   بالصرف، والمعاملة ممكن تكون اتصرفت **و** مالهاش دليل في نفس الوقت —
   فدول حاجتين مستقلتين. ده إقرار **المراجع** إنه بصّ وقرر.

   الملاحظة **إلزامية** (٣ حروف على الأقل) — زرار من غير سبب مكتوب
   بيسجّل إن حد ضغط، مش إن حد راجع. والهوية من bank_actor() يعني
   الاسم الحقيقي من التوكن مش الحساب المشترك.

   أثرها على الشاشة: المعاملة بتخرج من عدّاد «يحتاج مراجعة» (الطابور
   بينقص وانت بتشتغل) وبتروح لشريحة «📝 راجعتها بملاحظة» اللي بتظهر
   بس لما يكون فيها حاجة. الحالة الأصلية (بلا تفسير / المصدر ناقص /
   لا يوجد كشف) بتفضل زي ما هي في عمود الحالة — المراجعة اليدوية
   مابتغيّرش الحقيقة، بتسجّل إن حد اتعامل معاها.

   الباقي نسخة حرفية من 223. */

create table if not exists public.card_review_notes (
  branch    text        not null,
  fh_id     bigint      not null,
  note      text        not null,
  by_user   text        not null,
  noted_at  timestamptz not null default now(),
  constraint card_review_notes_pk primary key (branch, fh_id),
  constraint card_review_notes_note_chk check (length(btrim(note)) >= 3)
);

comment on table public.card_review_notes is
  'إقرار المراجع إنه بصّ على معاملة فيزا غير مطابقة وكتب سببها. مستقل عن shift_txn_reviews (إقرار الصيدلي بالصرف).';

alter table public.card_review_notes enable row level security;
revoke all on table public.card_review_notes from anon, authenticated;
grant select, insert, update, delete on table public.card_review_notes to service_role;

/* تأكيد المراجعة بملاحظة. upsert عشان المراجع يقدر يعدّل صياغته،
   وكل تعديل بيسجّل مين آخر واحد كتب وإمتى. */
create or replace function public.confirm_card_review(
  p_branch text, p_fh_id bigint, p_note text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_by text; v_note text;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  v_note := btrim(coalesce(p_note,''));
  if length(v_note) < 3 then
    raise exception 'اكتب ملاحظة توضّح سبب المراجعة' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cashier_transactions c
                  where c.branch = p_branch and c.fh_id = p_fh_id) then
    raise exception 'الحركة غير موجودة' using errcode = 'P0002';
  end if;

  v_by := public.bank_actor();
  insert into card_review_notes (branch, fh_id, note, by_user)
  values (p_branch, p_fh_id, v_note, v_by)
  on conflict (branch, fh_id) do update
    set note = excluded.note, by_user = excluded.by_user, noted_at = now();

  return jsonb_build_object('success', true, 'by', v_by, 'note', v_note,
           'at', to_char(now() at time zone 'Africa/Cairo','MM-DD HH24:MI'));
end $function$;

create or replace function public.unconfirm_card_review(
  p_branch text, p_fh_id bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  delete from card_review_notes where branch = p_branch and fh_id = p_fh_id;
  return jsonb_build_object('success', true);
end $function$;

comment on function public.confirm_card_review(text, bigint, text) is
  'المراجع بيأكّد إنه بصّ على معاملة غير مطابقة ويكتب السبب. الملاحظة إلزامية. بتخرج المعاملة من عدّاد «يحتاج مراجعة».';

revoke all on function public.confirm_card_review(text, bigint, text)   from public, anon;
revoke all on function public.unconfirm_card_review(text, bigint)       from public, anon;
grant execute on function public.confirm_card_review(text, bigint, text) to authenticated, service_role;
grant execute on function public.unconfirm_card_review(text, bigint)     to authenticated, service_role;

create or replace function public.bind_card_evidence()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  /* ⚠️ نافذة المحفظة اتوسّعت من ٤ لـ١٢ ساعة بقرار المالك 2026-11-19
     بعد بلاغ فاتورة 1516529 (فاتت بـ٤٨ دقيقة). الماكينة فاضلة ±ساعتين. */
  WIN_SMS_BEFORE constant interval := interval '12 hours';
  WIN_SMS_AFTER  constant interval := interval '1 hour';
  WIN_MCH_BEFORE constant interval := interval '2 hours';
  WIN_MCH_AFTER  constant interval := interval '2 hours';
  AGE            constant interval := interval '5 minutes';
  LOOKBACK       constant interval := interval '7 days';
  v_since timestamptz;
  v_now   timestamptz := now();
  r       record;
  v_id    bigint;
  v_ts    timestamptz;
  v_n     int := 0;
  v_seen  int := 0;
begin
  select o.card_bind_since into v_since from org_settings o where o.id = 1;
  if v_since is null then
    return jsonb_build_object('ok', false, 'reason', 'card_bind_since فاضية');
  end if;

  for r in
    /* ⚠️ actual_date مخزّن naive بتوقيت القاهرة، وcreatedAt بتاع الكشف
       timestamptz حقيقي — التحويل صريح عشان مانعتمدش على TimeZone الجلسة. */
    select c.branch, c.fh_id,
           (c.actual_date at time zone 'Africa/Cairo') as txn_at,
           case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then round(c.visa_no::numeric, 2) else round(c.amount, 2) end as amt,
           case when btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$' then 'num'
                when c.channel ~* '^paymob'                         then 'mch'
                else 'co' end as kind,
           case when btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$' then btrim(c.channel)
                when c.channel ~* '^paymob' then lower(replace(btrim(coalesce(c.channel,'')), ' ', ''))
                else btrim(coalesce(c.channel,'')) end as key_used
      from cashier_transactions c
     where coalesce(c.is_visa,0) = 1
       and ( btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$'
          or c.channel ~* '^paymob'
          or c.channel ~* 'vodaf|orange|wee|etisalat' )
       and (c.actual_date at time zone 'Africa/Cairo') >= greatest(v_since, v_now - LOOKBACK)
       and (c.actual_date at time zone 'Africa/Cairo') <= v_now - AGE
       and not exists (select 1 from card_evidence_links l
                        where l.branch = c.branch and l.fh_id = c.fh_id)
     order by c.actual_date, c.fh_id       -- الأقدم بياخد الأول
  loop
    v_seen := v_seen + 1;
    v_id := null; v_ts := null;

    if r.kind = 'num' then
      select s.id, s."createdAt" into v_id, v_ts
        from wallet_sms s
       where s.type = 'استلام'
         and public.branch_code_of(s.branch) = public.branch_code_of(r.branch)
         and btrim(coalesce(s.to_no,'')) = r.key_used      -- نفس رقم المحفظة بالظبط
         and round(s.ammount, 2) = r.amt                   -- نفس القيمة بالقرش
         and s."createdAt" between r.txn_at - WIN_SMS_BEFORE and r.txn_at + WIN_SMS_AFTER
         and not exists (select 1 from card_evidence_links l
                          where l.src = 'sms' and l.src_id = s.id)   -- لسه حرّة
       order by abs(extract(epoch from s."createdAt" - r.txn_at))
       limit 1;

    elsif r.kind = 'co' then
      /* محفظة باسم الشركة: مفيش رقم في القناة نربط بيه، فالفرع والقيمة بس */
      select s.id, s."createdAt" into v_id, v_ts
        from wallet_sms s
       where s.type = 'استلام'
         and public.branch_code_of(s.branch) = public.branch_code_of(r.branch)
         and round(s.ammount, 2) = r.amt
         and s."createdAt" between r.txn_at - WIN_SMS_BEFORE and r.txn_at + WIN_SMS_AFTER
         and not exists (select 1 from card_evidence_links l
                          where l.src = 'sms' and l.src_id = s.id)
       order by abs(extract(epoch from s."createdAt" - r.txn_at))
       limit 1;

    else
      select w.id, w."createdAt" into v_id, v_ts
        from wallet w
       where w.machine_name is not null
         and public.branch_code_of(w.branch) = public.branch_code_of(r.branch)
         and lower(replace(btrim(w.machine_name), ' ', '')) = r.key_used  -- نفس الماكينة بالظبط
         and round(w.ammount, 2) = r.amt
         and w."createdAt" between r.txn_at - WIN_MCH_BEFORE and r.txn_at + WIN_MCH_AFTER
         and not exists (select 1 from card_evidence_links l
                          where l.src = 'machine' and l.src_id = w.id)
       order by abs(extract(epoch from w."createdAt" - r.txn_at))
       limit 1;
    end if;

    if v_id is not null then
      begin
        insert into card_evidence_links (branch, fh_id, src, src_id, key_used, amount, txn_at, src_at, gap_min)
        values (r.branch, r.fh_id, case when r.kind = 'mch' then 'machine' else 'sms' end,
                v_id, r.key_used, r.amt, r.txn_at, v_ts,
                round(extract(epoch from v_ts - r.txn_at)/60)::int);
        v_n := v_n + 1;
      exception when unique_violation then
        null;   -- الدليل اتحجز في نفس اللحظة؛ الدورة الجاية تحاول بدليل تاني
      end;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'checked', v_seen, 'bound', v_n,
                            'at', to_char(v_now at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI:SS'));
end $function$;

comment on function public.bind_card_evidence() is
  'كل دقيقة: أي معاملة فيزا (محفظة برقمها أو باسم شركتها، أو باي موب) عدى عليها ٥ دقايق ولسه مش مربوطة — بيدوّر لها على دليل حر بنفس القيمة بالقرش جوّه النافذة ويربطه بيها نهائيًا. الأقدم بياخد الأول. فورى وإنستاباي برّا.';

revoke all on function public.bind_card_evidence() from public, anon, authenticated;
grant execute on function public.bind_card_evidence() to service_role;


CREATE OR REPLACE FUNCTION public.get_card_review(p_branch text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_state text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from date; v_to date; v_lim int; v_off int; v_br text; v_role text; v_all boolean;
  v_since timestamptz;   -- بداية العمل بالنظام: «لم يصرف» بيعدّ من هنا
  v_bind  timestamptz;   -- من هنا والحالة من الدفتر مش من حساب لحظي
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

  /* الحد الأدنى من الإعدادات. الملاذ ثابت عشان الدالة ماتفشلش لو الصف اتمسح،
     ومابيعتمدش على min() من الجدول — ده كان هيجيب 2026-10-04 ويغرق الشريط. */
  select o.card_unpaid_since into v_since from public.org_settings o where o.id = 1;
  v_since := coalesce(v_since, timestamp '2026-11-14 09:00' at time zone 'Africa/Cairo');
  select o.card_bind_since into v_bind from public.org_settings o where o.id = 1;
  /* ملاذ بعيد في المستقبل: لو الإعداد فاضي يبقى المحرّك لسه ما اتركّبش،
     فكل حاجة تفضل على الحساب الحي بدل ما تطلع «بلا تفسير» بالغلط. */
  v_bind := coalesce(v_bind, 'infinity'::timestamptz);

  /* «لم يصرف» بتتجاهل خانتي التاريخ عن قصد — هي رصيد متأخرات مش تقرير يوم.
     الشاشة بتعرض النافذة الفعلية من win_from/win_to. */
  if coalesce(p_state,'') in ('unpaid','paid_nomatch') then
    v_from := least(v_from, (v_since at time zone 'Africa/Cairo')::date);
    v_to   := greatest(v_to, (now() at time zone 'Africa/Cairo')::date);
  end if;

  with
  t as (
    select c.branch, c.fh_id, c.actual_date, c.amount, c.channel, c.visa_no, c.visa_name, c.sth_id,
           c.user_name, c.computer, c.notes, c.from_name, c.to_name, c.cust_name, c.cust_code,
           (c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1) as manual,
           case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then c.visa_no::numeric else c.amount end as paid_val,
           r.reviewed_by, r.reviewed_at, r.paid as rv_paid, r.channel as rv_channel, r.note as rv_note, r.note_src as rv_src,
           /* 'sms_no' = القناة رقم محفظة (حساب لكل رقم). لازم تيجي قبل
              فحص أسماء الشركات عشان الرقم مايقعش في 'none'. */
           case when c.channel ~* '^paymob'                         then 'machine'
                when btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$' then 'sms_no'
                when c.channel ~* 'vodaf|orange|wee|etisalat'       then 'sms'
                else 'none' end as feed
      from cashier_transactions c
      left join shift_txn_reviews r on r.branch = c.branch and r.fh_id = c.fh_id
     where coalesce(c.is_visa,0) = 1
       and (c.actual_date at time zone 'Africa/Cairo')::date between v_from and v_to
       and (coalesce(p_state,'') not in ('unpaid','paid_nomatch') or c.actual_date >= v_since)
       and (v_br is null or c.branch = v_br)
  ),
  /* عدّاد الشريط: مستقل تمامًا عن نطاق التاريخ وعن منطق المطابقة.
     مسح واحد بالفهرس على actual_date — عشان الرقم اللي في الشريط يفضل
     صادق حتى وانت واقف على يوم واحد. */
  u as (
    select case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then c.visa_no::numeric else c.amount end as paid_val
      from cashier_transactions c
      left join shift_txn_reviews r on r.branch = c.branch and r.fh_id = c.fh_id
     where coalesce(c.is_visa,0) = 1
       and r.reviewed_by is null
       and c.actual_date >= v_since
       and (v_br is null or c.branch = v_br)
  ),
  wm as (
    select id, public.branch_code_of(branch) as bc, "createdAt" as ts,
           round(ammount,2) as amt, machine_name, order_id
      from wallet
     where ("createdAt" at time zone 'Africa/Cairo')::date between v_from - 1 and v_to + 1
  ),
  ws as (
    select id, public.branch_code_of(branch) as bc, "createdAt" as ts,
           round(ammount,2) as amt, to_no, op_ref
      from wallet_sms
     where type = 'استلام'
       and ("createdAt" at time zone 'Africa/Cairo')::date between v_from - 1 and v_to + 1
  ),
  gaps as (select * from public.wallet_sms_gaps(v_from, v_to)),
  /* الدفتر: الربط اللي المحرّك سجّله. الدليل برقمه وفارقه الزمني عشان
     المراجع يقدر يروح يدوّر عليه بنفسه في شاشة المحافظ. */
  lnk as (
    select l.fh_id, l.branch,
           case when l.src = 'sms'
                then 'محفظة ' || coalesce(sm.to_no, l.key_used, '') ||
                     coalesce(' · ' || nullif(sm.op_ref,''), '')
                else 'ماكينة ' || coalesce(wl.machine_name, l.key_used, '') ||
                     coalesce(' · ' || nullif(wl.order_id,''), '')
           end || ' · ' ||
           case when l.gap_min < 0 then abs(l.gap_min)::text || ' د قبل'
                when l.gap_min > 0 then l.gap_min::text || ' د بعد'
                else 'نفس الدقيقة' end as ev
      from card_evidence_links l
      join t on t.branch = l.branch and t.fh_id = l.fh_id
      left join wallet_sms sm on l.src = 'sms'     and sm.id = l.src_id
      left join wallet     wl on l.src = 'machine' and wl.id = l.src_id
  ),
  /* المراجعة اليدوية: المراجع بصّ وكتب سبب. بتخرج من طابور الشغل
     لكن الحالة الأصلية بتفضل زي ما هي — ده إقرار مش تغيير حقيقة. */
  crn as (
    select nt.branch, nt.fh_id, nt.note, nt.by_user, nt.noted_at
      from card_review_notes nt
      join t on t.branch = nt.branch and t.fh_id = nt.fh_id
  ),
  /* المطابقة: أقرب حركة زمنيًا **بشرط التبادل** — الزوج بيتقبل لما
     المعاملة تكون أقرب معاملة للحركة والحركة أقرب حركة للمعاملة.
     الترتيب التسلسلي القديم كان بيجوّز المعاملة رقم N للحركة رقم N،
     فأي فرق في العدد بيزحزح كل اللي بعده ويوقّعه برّا النافذة. */
  cand as (
    select t.fh_id, t.branch, 'm:' || w.id::text as sid,
           abs(extract(epoch from w.ts - t.actual_date)) as d,
           'ماكينة ' || coalesce(w.machine_name, '') ||
           coalesce(' · ' || nullif(w.order_id,''), '') as ev
      from t join wm w on w.bc = t.branch and w.amt = t.paid_val
     where t.feed = 'machine' and (t.actual_date at time zone 'Africa/Cairo') < v_bind
       and w.ts between t.actual_date - interval '2 hours'
                    and t.actual_date + interval '2 hours'
    union all
    select t.fh_id, t.branch, 's:' || s.id::text,
           abs(extract(epoch from s.ts - t.actual_date)),
           'محفظة ' || coalesce(s.to_no,'') || coalesce(' · ' || nullif(s.op_ref,''), '')
      from t join ws s on s.bc = t.branch and s.amt = t.paid_val
     where t.feed = 'sms' and (t.actual_date at time zone 'Africa/Cairo') < v_bind
       and s.ts between t.actual_date - interval '2 hours'
                    and t.actual_date + interval '2 hours'
    union all
    /* نافذة غير متماثلة عن قصد: العميل بيحوّل الأول والفاتورة بتتعمل
       بعدين — فـ١٢ ساعة قبل مقابل ساعة بعد. والرسالة بعد المعاملة
       نادرة أصلًا (٩ حالات في القياس، كلها خلال ساعة). */
    select t.fh_id, t.branch, 's:' || s.id::text,
           abs(extract(epoch from s.ts - t.actual_date)),
           'محفظة ' || coalesce(s.to_no,'') || coalesce(' · ' || nullif(s.op_ref,''), '')
      from t join ws s on s.bc = t.branch and s.amt = t.paid_val
                      and btrim(coalesce(s.to_no,'')) = btrim(coalesce(t.channel,''))
     where t.feed = 'sms_no' and (t.actual_date at time zone 'Africa/Cairo') < v_bind
       and s.ts between t.actual_date - interval '12 hours'
                    and t.actual_date + interval '1 hour'
  ),
  best_t as (select distinct on (fh_id, branch) * from cand order by fh_id, branch, d, sid),
  best_s as (select distinct on (sid) * from cand order by sid, d, fh_id),
  hit as (
    select fh_id, branch, ev from lnk          -- المسجّل (بعد نقطة البداية)
    union all
    select bt.fh_id, bt.branch, bt.ev          -- الحساب الحي (قبلها)
      from best_t bt
      join best_s bs on bs.sid = bt.sid and bs.fh_id = bt.fh_id and bs.branch = bt.branch
  ),
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
           cn.note as rn_note, cn.by_user as rn_by, cn.noted_at as rn_at,
           case when h.fh_id is null and sg.fh_id is not null
                then sg.party || ' (' ||
                     case when sg.dv > 0 then 'فرق ' || sg.dv::text || ' ج · ' else '' end ||
                     'بفارق ' || sg.dm::text || ' دقيقة)' end as sugg_t,
           case
             when t.feed = 'none' then 'no_feed'
             when h.fh_id is not null then 'matched'
             /* لسه مامرّش ٥ دقايق — المحرّك ما وصلهاش. ماينفعش نتّهمها. */
             when (t.actual_date at time zone 'Africa/Cairo') >= v_bind
              and (t.actual_date at time zone 'Africa/Cairo') > now() - interval '5 minutes'
                  then 'checking'
             when t.feed = 'sms' and exists (
                    select 1 from gaps g where g.branch_code = t.branch
                     and t.actual_date between g.gap_from and g.gap_to) then 'feed_gap'
             when t.feed = 'sms_no' and not exists (
                    select 1 from ws s where s.bc = t.branch
                     and btrim(coalesce(s.to_no,'')) = btrim(coalesce(t.channel,''))
                     and s.ts between t.actual_date - interval '12 hours'
                                  and t.actual_date + interval '1 hour') then 'feed_gap'
             when t.feed = 'sms_no' and exists (
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
             left join crn cn on cn.fh_id = t.fh_id and cn.branch = t.branch
  ),
  f as (
    select * from j
     where p_state is null
        or (p_state = 'pending' and state = 'unexplained' and reviewed_by is null)
        or (p_state = 'unpaid' and reviewed_by is null)
        or (p_state = 'paid_nomatch' and state = 'unexplained' and reviewed_by is not null)
        or (p_state = 'review' and state <> 'matched' and rn_by is null)
        or (p_state = 'confirmed' and rn_by is not null)
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
    'unpaid_n',   (select count(*) from u),
    'unpaid_val', (select coalesce(round(sum(paid_val)),0) from u),
    'matched_n',   (select count(*) from j where state = 'matched'),
    'matched_val', (select coalesce(round(sum(paid_val)),0) from j where state = 'matched'),
    /* الطابور = غير مطابق **ولسه محدش راجعه** — بينقص وانت بتشتغل */
    'review_n',    (select count(*) from j where state <> 'matched' and rn_by is null),
    'review_val',  (select coalesce(round(sum(paid_val)),0) from j where state <> 'matched' and rn_by is null),
    'confirmed_n',   (select count(*) from j where rn_by is not null),
    'confirmed_val', (select coalesce(round(sum(paid_val)),0) from j where rn_by is not null),
    'paid_nomatch_n',   (select count(*) from j where state = 'unexplained' and reviewed_by is not null),
    'paid_nomatch_val', (select coalesce(round(sum(paid_val)),0) from j where state = 'unexplained' and reviewed_by is not null),
    'unpaid_since', to_char(v_since at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI'),
    'win_from', v_from::text,
    'win_to',   v_to::text,
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
        'state', state, 'evidence', ev, 'suggest', sugg_t,
        'rn', case when rn_by is null then null else jsonb_build_object(
                 'by', rn_by, 'note', rn_note,
                 'at', to_char(rn_at at time zone 'Africa/Cairo','MM-DD HH24:MI')) end
      ) order by ord), '[]'::jsonb)
      from (select *, row_number() over (order by actual_date desc, fh_id desc) ord
              from f order by actual_date desc, fh_id desc
             limit v_lim offset v_off) p)
  ) into v_out;
  return v_out;
end $function$;

comment on function public.get_card_review(text, date, date, text, integer, integer)
  is 'مراجعة تحصيل البطاقات. p_state: review (غير مطابق ولسه محدش راجعه — الافتراضي) | confirmed (راجعه المراجع بملاحظة) | matched | unexplained | feed_gap | no_feed | checking | pending | unpaid | paid_nomatch. المعاملة بعد org_settings.card_bind_since حالتها من card_evidence_links؛ اللي قبلها على الحساب الحي.';
