/* migrate_220 — ربط المعاملة بدليلها مرة واحدة ويتسجّل (قرار المالك 2026-11-18)

   قبل كده الشاشة كانت **بتعيد الحساب من الأول** كل فتحة، فمعاملة النهاردة
   ممكن تخطف دليل معاملة امبارح لو طلعت أقرب ليها زمنيًا.
   المطلوب كما حدّده المالك: أول ما المعاملة يعدّي عليها ٥ دقايق، ندوّر لها
   على دليلها، ولو لقيناه **نربطه بيها بالاسم والدليل يتحرق** — معاملة تانية
   بنفس القيمة على نفس المحفظة مش هتعرف تاخده مهما حصل، وتروح مراجعة.
   الأقدم بياخد الأول.

   الحد الفاصل: org_settings.card_bind_since — بيبدأ من لحظة التركيب.
   اللي قبلها يفضل على الحساب الحي زي ما هو (قرار المالك: نبدأ من دلوقتي).

   برّا المحرّك عن قصد:
   · **فورى** — مفيش ليها كشف خالص؛ مراجعة يدوية (قرار المالك: سيبها زي ما هي).
   · **إنستاباي** — بتتقارن بملف البنك وقت سحبه، مش من هنا.
   · الكاش والصرف والتوريد — مالهمش علاقة.

   النوافذ من قياس البيانات مش من التخمين (شوف migrate_219):
   · محفظة: من ٤ ساعات قبل المعاملة لساعة بعدها — العميل بيحوّل الأول
     والفاتورة بتتعمل بعدين (٩٤٪ من المطابقات في المدى ده).
   · ماكينة: ±ساعتين — السحب بيحصل لحظة الفاتورة.

   اختبار قبل التشغيل (يومين بيانات حقيقية، واتمسحت بعده):
     checked 290 · bound 196 · أدلة مميّزة 196 (يعني **مفيش دليل اتاخد مرتين**)
     ١٠٠ محفظة · ٩٦ ماكينة · متوسط الفارق ٢٥ دقيقة · أقصاه ٢٣٨ دقيقة
   والفاتورتين اللي المالك سأل عنهم اتربطوا صح:
     1516250 ← رسالة 11539 (١٦٥ د قبل) · 1516380 ← رسالة 11551 (٤٥ د قبل) */

create table if not exists public.card_evidence_links (
  branch     text        not null,
  fh_id      bigint      not null,
  src        text        not null,
  src_id     bigint      not null,
  key_used   text,
  amount     numeric,
  txn_at     timestamptz not null,
  src_at     timestamptz not null,
  gap_min    integer,
  bound_at   timestamptz not null default now(),
  constraint card_evidence_links_pk       primary key (branch, fh_id),
  /* 🔑 ده قلب الموضوع: حركة الكشف الواحدة متربطة بمعاملة واحدة بس.
     القيد على مستوى القاعدة مش على مستوى الكود — عشان حتى لو اتنين
     اشتغلوا في نفس اللحظة واحد بس هينجح. */
  constraint card_evidence_links_src_once unique (src, src_id),
  constraint card_evidence_links_src_chk  check (src in ('sms','machine','bank'))
);

comment on table public.card_evidence_links is
  'ربط ثابت بين معاملة فيزا ودليلها في الكشف (رسالة محفظة / حركة ماكينة / سطر بنك). الدليل بيتحرق: unique(src,src_id).';

alter table public.card_evidence_links enable row level security;
revoke all on table public.card_evidence_links from anon, authenticated;
grant select, insert, update, delete on table public.card_evidence_links to service_role;

alter table public.org_settings add column if not exists card_bind_since timestamptz;
comment on column public.org_settings.card_bind_since is
  'من اللحظة دي والمعاملات بتتربط بدليلها ويتسجّل. اللي قبلها على الحساب الحي.';
update public.org_settings set card_bind_since = coalesce(card_unpaid_since, timestamp '2026-11-14 09:00' at time zone 'Africa/Cairo') where id = 1 and card_bind_since is null;   -- قرار المالك: نمشي على كل اللي من أول التشغيل

create index if not exists ix_wallet_sms_created on public.wallet_sms ("createdAt");
create index if not exists ix_wallet_created     on public.wallet ("createdAt");

create or replace function public.bind_card_evidence()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  /* النوافذ من قياس البيانات (migrate_219):
     المحفظة — العميل بيحوّل الأول والفاتورة بتتعمل بعدين: ٩٤٪ من
     المطابقات خلال ٤ ساعات قبل المعاملة، والرسالة بعدها نادرة وكلها
     خلال ساعة. الماكينة — السحب بيحصل لحظة الفاتورة فـ±ساعتين كفاية. */
  WIN_SMS_BEFORE constant interval := interval '4 hours';
  WIN_SMS_AFTER  constant interval := interval '1 hour';
  WIN_MCH_BEFORE constant interval := interval '2 hours';
  WIN_MCH_AFTER  constant interval := interval '2 hours';
  AGE            constant interval := interval '5 minutes';
  /* سقف المحاولة: بعد أسبوع الدليل مش هييجي، ومن غير السقف الحلقة
     هتعيد على كل معاملة قديمة كل دقيقة للأبد. */
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
       timestamptz حقيقي — التحويل صريح هنا عشان مانعتمدش على TimeZone
       بتاعة الجلسة. */
    select c.branch, c.fh_id,
           (c.actual_date at time zone 'Africa/Cairo') as txn_at,
           case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then round(c.visa_no::numeric, 2) else round(c.amount, 2) end as amt,
           case when btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$' then 'sms' else 'machine' end as src,
           case when btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$'
                then btrim(c.channel)
                else lower(replace(btrim(coalesce(c.channel,'')), ' ', '')) end as key_used
      from cashier_transactions c
     where coalesce(c.is_visa,0) = 1
       and ( btrim(coalesce(c.channel,'')) ~ '^01[0-9]{9}$' or c.channel ~* '^paymob' )
       and (c.actual_date at time zone 'Africa/Cairo') >= greatest(v_since, v_now - LOOKBACK)
       and (c.actual_date at time zone 'Africa/Cairo') <= v_now - AGE
       and not exists (select 1 from card_evidence_links l
                        where l.branch = c.branch and l.fh_id = c.fh_id)
     order by c.actual_date, c.fh_id       -- الأقدم بياخد الأول
  loop
    v_seen := v_seen + 1;
    v_id := null; v_ts := null;

    if r.src = 'sms' then
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
        values (r.branch, r.fh_id, r.src, v_id, r.key_used, r.amt, r.txn_at, v_ts,
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
  'كل دقيقة: أي معاملة فيزا (محفظة أو باي موب) عدى عليها ٥ دقايق ولسه مش مربوطة — بيدوّر لها على دليل حر بنفس الرقم/الماكينة ونفس القيمة بالقرش جوّه النافذة، ويربطه بيها نهائيًا. الأقدم بياخد الأول.';

revoke all on function public.bind_card_evidence() from public, anon, authenticated;
grant execute on function public.bind_card_evidence() to service_role;

/* النبضة: كل دقيقة. الاسم ثابت فإعادة التشغيل بتحدّث المهمة مش بتكرّرها. */
select cron.schedule('bind-card-evidence', '* * * * *', 'select public.bind_card_evidence();');
