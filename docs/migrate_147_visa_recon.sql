/* ============================================================
   مطابقة خزنة visa — الجداول والدوال
   ------------------------------------------------------------
   الفكرة (من المالك): كل تقفيلة وردية بيتصرف كل غير النقدي على خزنة
   اسمها «visa» في eplus. فرصيد visa المفروض يساوي:

     أرصدة المحافظ وفوري  (الرصيد المكتوب في آخر تقفيلة — رصيد فعلي)
   + باي موب غير المحصّل   (اللي لسه ما وصلش من البنك)
   + انستاباي غير المرحّل  (المسجّل في الشيفت ناقص اللي اترحّل منه)

   ⚠️ **ممنوع** استعمال حسابات النوع 3 في eplus كمصدر للأرصدة — اتفحصت
   وطلعت مش بتتابع الرصيد الحقيقي: «فورى 313» عندها −1,544 بينما
   الحقيقي 37,825، ومحفظة شغّالة بـ126 ألف **مالهاش حساب أصلًا**.
   المصادر التلاتة فوق هي الصح (قرار المالك بعد المراجعة).

   ⚠️ انستاباي: الشيفت اللي **اترحّل بالكامل** بيدّي صفر مهما كان الفرق
   بين المسجّل وحركات البنك. الشيفت اللي لسه فيه حركة غير مرحّلة —
   أو اللي كشف البنك ماوصلوش أصلًا — بياخد (المسجّل − اللي اترحّل).
   كده ما نعدّش فلوس خرجت من visa مرتين، وفي نفس الوقت فلوس اليومين
   اللي الملف لسه مارفعش لهم بتتحسب كاملة (وهي فعلًا لسه في visa).

   ⚠️ مفيش تاريخ لرصيد الخزنة في eplus: سجل تغيّر الأرصدة فاضي،
   وجداول حركات الخزائن فاضية، ودفتر اليومية بيربط بالحساب المحاسبي
   مش بالخزنة (انستاباي وكل المحافظ على حساب واحد، وكل الماكينات على
   حساب تاني). فالمتاح هو **الرصيد اللحظي بس** — وعشان كده كل مراجعة
   بتتسجّل كلقطة، والتاريخ بيتكوّن من المراجعات نفسها.

   ⚠️ أسماء الفروع مكتوبة بشكلين («سيدى بشر» بالمقصورة في pos_shifts
   و«سيدي بشر» بالياء في wallet) — فكل مطابقة بتعدّي على `branches`
   بالاسم أو الأسماء البديلة، مش بالمقارنة الحرفية.
   ============================================================ */

/* ── (1) أرصدة خزائن eplus — المحرّك بيحدّثها ── */
create table if not exists public.eplus_safes (
  branch      text    not null,          -- كود الفرع الإنجليزي (المحرّك بيعرفه كده)
  fcs_id      integer not null,
  fcs_code    text,
  name_ar     text,
  fcs_type    integer,                   -- 1 نقطة/خزنة · 2 خزنة · 3 حساب غير نقدي
  active      integer,
  balance     numeric(14,4),
  synced_at   timestamptz not null default now(),
  primary key (branch, fcs_id)
);
comment on table public.eplus_safes is
  'لقطة أرصدة F_Cash_Store من eplus لكل فرع — بيحدّثها محرّك المزامنة (مهمة safes).';

/* ── (2) تاريخ المراجعات ── */
create table if not exists public.visa_recon_snapshots (
  id          bigserial primary key,
  branch      text not null,             -- اسم الفرع بالعربي (زي باقي شاشات الخزنة)
  taken_at    timestamptz not null default now(),
  visa        numeric(14,2),
  wallets     numeric(14,2),
  paymob      numeric(14,2),
  insta       numeric(14,2),
  src_total   numeric(14,2),
  gap         numeric(14,2),
  taken_by    text
);
create index if not exists idx_visa_recon_branch_at
  on public.visa_recon_snapshots (branch, taken_at desc);

/* ── (3) توحيد اسم الفرع — `branch_code_of` موجودة أصلًا في القاعدة
       وبتعمل نفس التوحيد بالحرف (الاسم · الكود · الأسماء البديلة · ي/ى)،
       فمفيش داعي نعرّفها تاني. ⚠️ ممنوع تغيير اسم معاملها — دوال تانية
       بتناديها. ── */

/* ── (4) الحساب اللحظي ── */
create or replace function public.get_visa_recon(p_branch text default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE v_out jsonb;
BEGIN
  IF coalesce(current_setting('request.jwt.claims', true),'') <> '' THEN
    PERFORM public.require_app_role(array['admin','manager','accountant']);
  END IF;

  WITH br AS (
    select b.name, b.code from branches b
     where b.is_active and (p_branch is null or b.code = public.branch_code_of(p_branch))
  ),
  /* أ) المحافظ وفوري — آخر رصيد مكتوب في التقفيلة لكل محفظة */
  w AS (
    select distinct on (br.code, l.method_key)
           br.code, l.method_key, l.display_name, l.closing_balance
      from br
      join pos_shifts s on public.branch_code_of(s.branch) = br.code and s.closed_at is not null
      join pos_shift_lines l on l.shift_id = s.id and l.method_type = 'wallet'
     order by br.code, l.method_key, s.closed_at desc
  ),
  /* ب) باي موب — غير المحصّل (لسه ما وصلش من البنك) */
  p AS (
    select br.code, coalesce(sum(x.ammount),0) amt, count(*) n, min(x."createdAt") oldest
      from br left join wallet x
        on public.branch_code_of(x.branch) = br.code
       and not coalesce(x.done,false) and coalesce(x.is_excess,false) = false
     group by br.code
  ),
  /* ج) انستاباي — نافذة كل وردية، والمرحّل منها */
  sh AS (
    select br.code, s.id, s.employee_name, s.closed_at,
           lag(s.closed_at) over (partition by br.code order by s.closed_at) prev,
           l.actual_amount declared
      from br
      join pos_shifts s on public.branch_code_of(s.branch) = br.code and s.closed_at is not null
      join pos_shift_lines l on l.shift_id = s.id and l.method_key = 'instapay'
  ),
  cov AS (select max(tx_at) mx from bank_transactions where source='instapay' and amount > 0),
  i AS (
    select sh.*, b.posted, b.pending,
           (sh.closed_at <= (select mx from cov)) covered
      from sh
      left join lateral (
        select coalesce(sum(t.amount) filter (where t.is_posted),0) posted,
               count(*) filter (where not t.is_posted) pending
          from bank_transactions t
         where t.source='instapay' and t.amount > 0
           and t.tx_at > sh.prev and t.tx_at <= sh.closed_at
      ) b on true
     where sh.prev is not null
  ),
  i2 AS (   /* الشيفت المرحّل بالكامل = صفر */
    select code, id, employee_name, closed_at,
           greatest(coalesce(declared,0) - coalesce(posted,0), 0) left_over
      from i
     where coalesce(pending,0) > 0 or not coalesce(covered,true)
  ),
  agg AS (
    select br.name, br.code,
           coalesce((select sum(closing_balance) from w where w.code=br.code),0) wallets,
           coalesce((select amt from p where p.code=br.code),0) paymob,
           coalesce((select sum(left_over) from i2 where i2.code=br.code),0) insta,
           (select e.balance from eplus_safes e
             where e.branch=br.code and lower(btrim(coalesce(e.name_ar,'')))='visa' limit 1) visa,
           (select max(e.synced_at) from eplus_safes e where e.branch=br.code) synced_at
      from br
  )
  select jsonb_build_object(
    'success', true,
    'branches', coalesce((select jsonb_agg(jsonb_build_object(
        'branch', a.name, 'code', a.code,
        'visa', a.visa, 'synced_at', a.synced_at,
        'wallets', round(a.wallets,2), 'paymob', round(a.paymob,2), 'insta', round(a.insta,2),
        'src_total', round(a.wallets + a.paymob + a.insta, 2),
        'gap', case when a.visa is null then null
                    else round(a.visa - (a.wallets + a.paymob + a.insta), 2) end,
        'wallet_lines', (select coalesce(jsonb_agg(jsonb_build_object(
              'name', coalesce(w.display_name, w.method_key), 'balance', round(w.closing_balance,2))
              order by w.closing_balance desc), '[]'::jsonb) from w where w.code=a.code),
        'paymob_n', (select n from p where p.code=a.code),
        'paymob_oldest', (select oldest from p where p.code=a.code),
        'insta_lines', (select coalesce(jsonb_agg(jsonb_build_object(
              'emp', i2.employee_name, 'at', i2.closed_at, 'amount', round(i2.left_over,2))
              order by i2.closed_at), '[]'::jsonb) from i2 where i2.code=a.code and i2.left_over > 0)
      ) order by a.name) from agg a), '[]'::jsonb)
  ) into v_out;
  RETURN v_out;
END $function$;

/* ── (5) حفظ لقطة بعد المراجعة ── */
create or replace function public.save_visa_recon_snapshot(p_branch text default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb,'{}'::jsonb);
  v_who text; v_n int;
BEGIN
  IF coalesce(current_setting('request.jwt.claims', true),'') <> '' THEN
    PERFORM public.require_app_role(array['admin','manager','accountant']);
  END IF;
  v_who := nullif(btrim(coalesce(claims->'app_metadata'->>'full_name',
                                 claims->'app_metadata'->>'username','')),'');

  INSERT INTO visa_recon_snapshots (branch, visa, wallets, paymob, insta, src_total, gap, taken_by)
  SELECT x->>'branch', (x->>'visa')::numeric, (x->>'wallets')::numeric,
         (x->>'paymob')::numeric, (x->>'insta')::numeric,
         (x->>'src_total')::numeric, (x->>'gap')::numeric, v_who
    FROM jsonb_array_elements((public.get_visa_recon(p_branch)) -> 'branches') x
   WHERE x->>'visa' is not null;      -- فرع مالوش رصيد visa مايتسجّلش
  GET DIAGNOSTICS v_n = row_count;

  RETURN jsonb_build_object('success', true, 'saved', v_n);
END $function$;

/* ── (6) طلب سحب لحظي من المحرّك ── */
create or replace function public.request_visa_refresh()
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE v_id bigint; v_pending int;
BEGIN
  IF coalesce(current_setting('request.jwt.claims', true),'') <> '' THEN
    PERFORM public.require_app_role(array['admin','manager','accountant']);
  END IF;

  /* طلب معلّق موجود = ما نكرّرش، نرجّع بتاعه */
  SELECT id INTO v_id FROM sync_requests
   WHERE job_id='safes' AND status IN ('pending','running')
   ORDER BY requested_at DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'request_id', v_id, 'reused', true);
  END IF;

  INSERT INTO sync_requests (job_id, branch, kind, status)
  VALUES ('safes', null, 'incr', 'pending') RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'request_id', v_id, 'reused', false);
END $function$;

/* ── (7) حالة الطلب (للشاشة وهي مستنية) ── */
create or replace function public.get_visa_refresh_status(p_id bigint)
returns jsonb
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select jsonb_build_object(
    'success', true, 'status', r.status, 'message', r.message,
    'requested_at', r.requested_at, 'done_at', r.done_at,
    'waited_seconds', round(extract(epoch from (now() - r.requested_at)))
  ) from sync_requests r where r.id = p_id;
$fn$;

/* ── (8) المهمة في المحرّك — صف بيانات، مفيش تعديل على السكربت ── */
insert into sync_jobs (id, name, source_db, enabled, interval_minutes, window_days,
                       window_refresh_minutes, steps, sort_order)
values ('safes', 'أرصدة الخزائن', 'Genius', false, 1440, 0, 0,
  '[{"select":"SELECT ''{branch}'' AS branch, fcs_id, fcs_code, fcs_name_ar AS name_ar, fcs_type, fcs_active AS active, fcs_current_balance AS balance FROM F_Cash_Store",
     "target":"eplus_safes","conflict":"branch,fcs_id"}]'::jsonb, 90)
on conflict (id) do update
  set steps = excluded.steps, name = excluded.name, updated_at = now();

insert into sync_branch_state (job_id, branch, enabled)
select 'safes', b.code, true from branches b where b.is_active
on conflict (job_id, branch) do update set enabled = true;

/* ⚠️ PUBLIC بياخد EXECUTE افتراضيًا — السحب الصريح لازم (migrate_89/90) */
revoke all on function public.get_visa_recon(text)            from public, anon;
revoke all on function public.save_visa_recon_snapshot(text)  from public, anon;
revoke all on function public.request_visa_refresh()          from public, anon;
revoke all on function public.get_visa_refresh_status(bigint) from public, anon;
grant execute on function public.get_visa_recon(text)            to authenticated, service_role;
grant execute on function public.save_visa_recon_snapshot(text)  to authenticated, service_role;
grant execute on function public.request_visa_refresh()          to authenticated, service_role;
grant execute on function public.get_visa_refresh_status(bigint) to authenticated, service_role;

revoke all on table public.eplus_safes, public.visa_recon_snapshots from public, anon;
grant select on public.eplus_safes, public.visa_recon_snapshots to authenticated;
grant all    on public.eplus_safes, public.visa_recon_snapshots to service_role;
grant usage, select on sequence public.visa_recon_snapshots_id_seq to service_role;
