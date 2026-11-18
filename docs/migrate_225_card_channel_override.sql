/* migrate_225 — تغيير حساب المعاملة بيتحفظ لحظيًا (بلاغ المالك 2026-11-19)

   البلاغ: «لما بغيّر من paymob 1 لـ paymob 7 مش بتتحفظ، وحصل خطأ أثناء
   الحفظ، ولما عدّلتها حصل صرف برضه على paymob 1».

   السبب: تغيير الحساب في الشاشة كان **في ذاكرة المتصفح بس**. مابيتبعتش
   للسيرفر إلا كجزء من review_shift_txn وقت الضغط على «تم». فلو الحفظ
   فشل لأي سبب (أشهرها حارس «يُرجى إرفاق صورة التحويل» لما المدفوع > 0
   والصورة لسه مارفعتش) — التعديل بيضيع خالص. وبعدين أي حد يفتح الشاشة
   أو يضغط «تم» بيشوف الحساب القديم ويصرف عليه.

   الحالة اللي حصلت فعلًا — فاتورة 1516554 (٨٩٥ ج · المعمورة · 19:32):
   القناة paymob 1، والدليل المقترح كان «ماكينة paymob7 بفارق ٩ دقايق».
   اتراجعت الساعة 23:36 على paymob 1 واتصرفت على paymob 1، وفضلت
   **غير مربوطة** لأن المحرّك دوّر على paymob 1 ومالقاش.
   (والتعديل بيشتغل لما الحفظ ينجح: ١٥ مراجعة من ١٠٦٦ غيّرت القناة
   فعلًا — فالمشكلة في النجاة من الفشل مش في الآلية.)

   الحل: جدول مستقل للتصحيح + دالة بتحفظه **لحظة الاختيار**، قبل أي
   مراجعة وبغض النظر عنها.

   🔑 والأهم: تغيير الحساب **بيلغي أي ربط قديم** للمعاملة — لأن الدليل
   اللي اتربط على الحساب الغلط بقى غلط. المحرّك بيدوّر من جديد على
   الحساب الصح في الدورة اللي بعدها. */

create table if not exists public.card_channel_overrides (
  branch   text        not null,
  fh_id    bigint      not null,
  channel  text        not null,
  by_user  text        not null,
  set_at   timestamptz not null default now(),
  constraint card_channel_overrides_pk primary key (branch, fh_id),
  constraint card_channel_overrides_chk check (length(btrim(channel)) > 0)
);

comment on table public.card_channel_overrides is
  'تصحيح حساب معاملة الفيزا (الكاشير اختار الحساب الغلط في eplus). بيتحفظ لحظة الاختيار ومستقل عن المراجعة.';

alter table public.card_channel_overrides enable row level security;
revoke all on table public.card_channel_overrides from anon, authenticated;
grant select, insert, update, delete on table public.card_channel_overrides to service_role;

create or replace function public.set_card_channel(
  p_branch text, p_fh_id bigint, p_channel text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_by text; v_ch text; v_unlinked int := 0;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بتعديل حركات الشيفت' using errcode = '42501';
  end if;
  v_ch := btrim(coalesce(p_channel,''));
  if v_ch = '' then
    raise exception 'اختار الحساب' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cashier_transactions c
                  where c.branch = p_branch and c.fh_id = p_fh_id) then
    raise exception 'الحركة غير موجودة' using errcode = 'P0002';
  end if;

  v_by := public.bank_actor();
  insert into card_channel_overrides (branch, fh_id, channel, by_user)
  values (p_branch, p_fh_id, v_ch, v_by)
  on conflict (branch, fh_id) do update
    set channel = excluded.channel, by_user = excluded.by_user, set_at = now();

  /* 🔑 الربط القديم اتعمل على الحساب الغلط — يتلغي عشان المحرّك يدوّر
     من جديد على الحساب الصح، والدليل القديم يرجع حر لمعاملة تانية. */
  delete from card_evidence_links
   where branch = p_branch and fh_id = p_fh_id;
  get diagnostics v_unlinked = row_count;

  return jsonb_build_object('success', true, 'channel', v_ch, 'by', v_by,
           'unlinked', v_unlinked,
           'at', to_char(now() at time zone 'Africa/Cairo','MM-DD HH24:MI'));
end $function$;

create or replace function public.clear_card_channel(
  p_branch text, p_fh_id bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بتعديل حركات الشيفت' using errcode = '42501';
  end if;
  delete from card_channel_overrides where branch = p_branch and fh_id = p_fh_id;
  delete from card_evidence_links     where branch = p_branch and fh_id = p_fh_id;
  return jsonb_build_object('success', true);
end $function$;

/* الشاشة بتجيب التصحيحات مرة واحدة بعد التحميل وتطبّقها على الصفوف،
   بدل ما نلمس get_current_shift وget_card_review. */
create or replace function public.get_card_channels(
  p_branch text DEFAULT NULL::text, p_days integer DEFAULT 14)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_out jsonb;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  select coalesce(jsonb_object_agg(o.branch || ':' || o.fh_id::text,
           jsonb_build_object('ch', o.channel, 'by', o.by_user,
             'at', to_char(o.set_at at time zone 'Africa/Cairo','MM-DD HH24:MI'))), '{}'::jsonb)
    into v_out
    from card_channel_overrides o
   where (p_branch is null or o.branch = p_branch)
     and o.set_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days,14), 90)));
  return v_out;
end $function$;

comment on function public.set_card_channel(text, bigint, text) is
  'تصحيح حساب معاملة فيزا. بيتحفظ فورًا (مش مستني «تم») وبيلغي أي ربط قديم عشان المحرّك يدوّر على الحساب الصح.';

revoke all on function public.set_card_channel(text, bigint, text) from public, anon;
revoke all on function public.clear_card_channel(text, bigint)     from public, anon;
revoke all on function public.get_card_channels(text, integer)     from public, anon;
grant execute on function public.set_card_channel(text, bigint, text) to authenticated, service_role;
grant execute on function public.clear_card_channel(text, bigint)     to authenticated, service_role;
grant execute on function public.get_card_channels(text, integer)     to authenticated, service_role;

/* المحرّك يقرا الحساب المصحَّح: coalesce(التصحيح, قناة الفاتورة).
   الباقي نسخة حرفية من 223/224. */
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
    with x as (
      select c.branch, c.fh_id, c.actual_date, c.amount, c.visa_no,
             /* التصحيح بيكسب قناة الفاتورة — الكاشير أحيانًا بيختار
                الحساب الغلط في eplus والمراجع بيصلّحه من الشاشة. */
             btrim(coalesce(ovr.channel, c.channel, '')) as ch
        from cashier_transactions c
        left join card_channel_overrides ovr
               on ovr.branch = c.branch and ovr.fh_id = c.fh_id
       where coalesce(c.is_visa,0) = 1
         and (c.actual_date at time zone 'Africa/Cairo') >= greatest(v_since, v_now - LOOKBACK)
         and (c.actual_date at time zone 'Africa/Cairo') <= v_now - AGE
         and not exists (select 1 from card_evidence_links l
                          where l.branch = c.branch and l.fh_id = c.fh_id)
    )
    select x.branch, x.fh_id,
           (x.actual_date at time zone 'Africa/Cairo') as txn_at,
           case when x.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and x.visa_no::numeric > 1
                then round(x.visa_no::numeric, 2) else round(x.amount, 2) end as amt,
           case when x.ch ~ '^01[0-9]{9}$' then 'num'
                when x.ch ~* '^paymob'     then 'mch'
                else 'co' end as kind,
           case when x.ch ~ '^01[0-9]{9}$' then x.ch
                when x.ch ~* '^paymob'     then lower(replace(x.ch, ' ', ''))
                else x.ch end as key_used
      from x
     where x.ch ~ '^01[0-9]{9}$'
        or x.ch ~* '^paymob'
        or x.ch ~* 'vodaf|orange|wee|etisalat'
     order by x.actual_date, x.fh_id       -- الأقدم بياخد الأول
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
  'كل دقيقة: أي معاملة فيزا (محفظة برقمها أو باسم شركتها، أو باي موب) عدى عليها ٥ دقايق ولسه مش مربوطة — بيدوّر لها على دليل حر بنفس القيمة بالقرش جوّه النافذة ويربطه بيها نهائيًا. الحساب من card_channel_overrides لو فيه تصحيح. الأقدم بياخد الأول. فورى وإنستاباي برّا.';

revoke all on function public.bind_card_evidence() from public, anon, authenticated;
grant execute on function public.bind_card_evidence() to service_role;
