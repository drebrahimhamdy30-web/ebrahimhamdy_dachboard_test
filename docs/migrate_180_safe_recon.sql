/* ════════════════════════════════════════════════════════════════
   مطابقة خزنة الفيزا: كشف النظام مقابل خزنة eplus   (2026-10-30)
   ----------------------------------------------------------------
   **ليه**: المالك صدّر إكسل من eplus وقارنه بـ«كشف حساب الخزنة»
   ولقى فروق. والسبب إن الاتنين مصدرين مختلفين بطبيعتهما:
     • كشف النظام = إغلاقات الشيفتات + تحويلات المحافظ + الصرف اليدوي
       (كلها بتتكتب من شاشاتنا)
     • خزنة eplus = اللي الموظف دخّله فيها بإيده
   فأي حركة تحصل في ناحية ومتتسجّلش في التانية بتفضل فرق **صامت**.
   اتقاس على المعمورة من ١٥/١٠: ٥٣ حركة مطابقة و٢١ فرق، أكبرهم
   ٣٣ ألف و٢٣ ألف فاضلين من ١٧ و٢١ أكتوبر — محدش كان واخد باله.

   🔑 **مفيش مزامنة جديدة محتاجة — وده اتأكد بالأرقام:**
   1. كشف النظام جداولنا (`pos_shifts` / `pos_wallet_transfers` /
      `pos_manual_transfers`) — لحظي بطبيعته.
   2. حركة خزنة eplus بتوصل في `cashier_transactions` كل **دقيقة**
      (مهمة `cashier_txns`). ونافذتها على **وقت الإدخال/التعديل**
      (`sec_insert_date OR sec_update_date`) مش على التاريخ المكتوب،
      ومعاها علامة مائية على رقم المستند — فالمستند المعاد تسجيله
      بأثر رجعي بيوصل (اتأكد: مستند 1596802 مكتوب عليه ٠٩:٣٠
      واتسجّل ٢١:٣٠ ووصل في نفس الدقيقة).
   3. **رصيد الخزنة**: مهمة `safes` موقوفة بقرار المالك (طلب لحظي).
      فبدل ما نجدولها، الرصيد **بيتحسب**: آخر لقطة محفوظة في
      `eplus_safes` + كل الحركات بعدها من `cashier_transactions`.
      ✔ اتقاس على المعمورة: لقطة عمرها **٦ أيام** (624,993.272) +
        حركة 176,539 = **801,532.272** — مطابق لرصيد eplus الحي
        **بفرق صفر**. يعني اللقطة ممكن تقدم من غير ما الرقم يبوظ.

   **المطابقة** على تلات مراحل، كلها على (الاتجاه + القيمة) مش على
   رقم المستند — لأن الجانبين مالهمش مرجع مشترك:
     ١) تطابق تام: نفس الاتجاه ونفس القيمة، والترتيب الزمني يحدّد
        أي حركة تقابل أي حركة لما تتكرر نفس القيمة.
     ٢) فرق كسور: نفس اليوم وفرق ≤ جنيه (مثال: 1,484.08 ↔ 1,484.00).
     ٣) تسجيل على دفعات: حركة عندنا = مجموع حركتين في الخزنة
        (مثال حقيقي: شيفت 8,056 وصل 6,556.81 + 1,499 بعد ٥ أيام).
   واللي يفضل بعد كده بيتعرض صراحةً على ناحيته.

   ⚠️ خزنة visa **رقمها مختلف لكل فرع** (المعمورة والسيوف 7، سان 17،
      بشر 19) — فالتعريف بالاسم `from_name/to_name = 'visa'` اللي
      المزامنة بتخزّنه مع الصف، مش برقم ثابت.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── نطاق الفرع لشاشة سجل الشيفتات (ساكت، بيرجّع اسم الفرع) ──── */
create or replace function public.shift_scope_branch()
returns text language plpgsql stable security definer set search_path = public as $fn$
declare v_role text := public.jwt_app_role(); v_all boolean; v_br text;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
  then return null; end if;
  if v_role is null then return '__none__'; end if;
  if v_role = 'admin'  then return null; end if;

  select pp.all_branches into v_all
    from page_permissions pp where pp.role = v_role and pp.page_key = 'shift_history';
  if v_all is null then
    select r.all_branches into v_all from role_branch_scope r where r.role = v_role;
  end if;
  if coalesce(v_all, false) then return null; end if;

  v_br := public.jwt_branch();
  return coalesce((select b.name from branches b
                    where b.name = v_br or v_br = any(coalesce(b.aliases,'{}'::text[])) limit 1),
                  '__none__');
end $fn$;

revoke all on function public.shift_scope_branch() from public, anon;
grant execute on function public.shift_scope_branch() to authenticated;

/* ── المطابقة ─────────────────────────────────────────────────── */
create or replace function public.get_safe_recon(
  p_branch text default null,
  p_from   date default null,
  p_to     date default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_scope text; v_name text; v_code text;
  v_from date; v_to date; v_out jsonb;
  v_anchor numeric; v_anchor_at timestamptz; v_eplus_bal numeric;
  v_open numeric; v_open_as_of date; v_ledger_bal numeric;
begin
  v_scope := public.shift_scope_branch();
  if v_scope = '__none__' then
    raise exception 'غير مصرّح: حسابك غير مربوط بفرع محدّد' using errcode = '42501';
  end if;
  /* بارامتر الفرع بيتجاهل لغير المصرّح — القايمة مش بتتفتح بتغيير الفلتر */
  v_name := coalesce(v_scope, nullif(btrim(coalesce(p_branch,'')),''));
  if v_name is null then
    raise exception 'اختر الفرع' using errcode = '22023';
  end if;
  v_code := public.branch_code_of(v_name);
  v_name := coalesce((select b.name from branches b where b.code = v_code), v_name);

  v_to   := coalesce(p_to, current_date);
  v_from := coalesce(p_from, v_to - 30);

  /* ── رصيد كشف النظام: رصيد البداية + كل الحركات بعده ───────── */
  select opening_balance, as_of into v_open, v_open_as_of
    from pos_branch_opening where branch = v_name;
  v_open := coalesce(v_open, 0); v_open_as_of := coalesce(v_open_as_of, date '2000-01-01');
  select v_open
       + coalesce((select sum(grand_total) from pos_shifts
                    where branch = v_name and (closed_at at time zone 'Africa/Cairo')::date >= v_open_as_of), 0)
       - coalesce((select sum(amount) from pos_wallet_transfers
                    where branch = v_name and (created_at at time zone 'Africa/Cairo')::date >= v_open_as_of), 0)
       - coalesce((select sum(amount) from pos_manual_transfers
                    where branch = v_name and (txn_date  at time zone 'Africa/Cairo')::date >= v_open_as_of), 0)
    into v_ledger_bal;

  /* ── رصيد خزنة eplus: آخر لقطة + الحركة بعدها (بدل جدولة) ─── */
  select balance, synced_at into v_anchor, v_anchor_at
    from eplus_safes where branch = v_code and lower(name_ar) = 'visa' limit 1;
  if v_anchor is not null then
    select v_anchor + coalesce(sum(case when c.to_name = 'visa' then c.amount else -c.amount end), 0)
      into v_eplus_bal
      from cashier_transactions c
     where c.branch = v_code
       and (c.from_name = 'visa' or c.to_name = 'visa')
       and c.actual_date > (v_anchor_at at time zone 'Africa/Cairo');
  end if;

  with
  /* ── الجانبان ─────────────────────────────────────────────── */
  ours as (
    select s.id::text as ref, 'شيفت'::text as kind,
           s.closed_at as ts,
           case when coalesce(s.grand_total,0) < 0 then 'out' else 'in' end as dir,
           round(abs(coalesce(s.grand_total,0))::numeric, 2) as amt,
           ('إغلاق شيفت ' || coalesce(s.shift_date::text,'')
             || coalesce(' — ' || nullif(s.employee_name,''), '')) as label
      from pos_shifts s
     where s.branch = v_name and s.closed_at is not null
       and (s.closed_at at time zone 'Africa/Cairo')::date between v_from and v_to
    union all
    select w.id::text, 'محفظة', w.created_at, 'out',
           round(coalesce(w.amount,0)::numeric, 2),
           'تحويل محفظة — ' || coalesce(w.display_name,'')
      from pos_wallet_transfers w
     where w.branch = v_name
       and (w.created_at at time zone 'Africa/Cairo')::date between v_from and v_to
    union all
    select m.id::text, 'يدوي', m.txn_date, 'out',
           round(coalesce(m.amount,0)::numeric, 2),
           'صرف — ' || coalesce(nullif(m.display_name,''), m.channel, '')
      from pos_manual_transfers m
     where m.branch = v_name
       and (m.txn_date at time zone 'Africa/Cairo')::date between v_from and v_to
  ),
  eplus as (
    select c.fh_id::text as ref, c.actual_date as ts,
           case when c.to_name = 'visa' then 'in' else 'out' end as dir,
           round(coalesce(c.amount,0)::numeric, 2) as amt,
           case when c.to_name = 'visa' then coalesce(c.from_name, 'حساب ' || c.from_id)
                else coalesce(c.to_name,  'حساب ' || c.to_id) end as party,
           nullif(btrim(coalesce(c.notes,'')),'') as note
      from cashier_transactions c
     where c.branch = v_code
       and (c.from_name = 'visa' or c.to_name = 'visa')
       and (c.actual_date at time zone 'Africa/Cairo')::date between v_from and v_to
  ),
  /* ── ١) تطابق تام: نفس الاتجاه والقيمة، والترتيب الزمني بيحدّد
         التقابل لما تتكرر نفس القيمة أكتر من مرة ─────────────── */
  o1 as (select *, row_number() over (partition by dir, amt order by ts, ref) rk from ours),
  e1 as (select *, row_number() over (partition by dir, amt order by ts, ref) rk from eplus),
  m1 as (
    select o.ref o_ref, o.kind, o.ts o_ts, o.dir, o.amt o_amt, o.label,
           e.ref e_ref, e.ts e_ts, e.amt e_amt, e.party, e.note
      from o1 o join e1 e on e.dir = o.dir and e.amt = o.amt and e.rk = o.rk
  ),
  /* ── ٢) فرق كسور: نفس اليوم وفرق ≤ جنيه ─────────────────── */
  ol as (select * from o1 where ref not in (select o_ref from m1)),
  el as (select * from e1 where ref not in (select e_ref from m1)),
  cand2 as (
    select o.ref o_ref, e.ref e_ref, abs(o.amt - e.amt) d,
           row_number() over (partition by o.ref order by abs(o.amt - e.amt),
                              abs(extract(epoch from e.ts - o.ts))) rn_o,
           row_number() over (partition by e.ref order by abs(o.amt - e.amt),
                              abs(extract(epoch from e.ts - o.ts))) rn_e
      from ol o join el e
        on e.dir = o.dir
       and abs(o.amt - e.amt) > 0 and abs(o.amt - e.amt) <= 1
       and abs(extract(epoch from e.ts - o.ts)) <= 86400
  ),
  m2 as (
    select o.ref o_ref, o.kind, o.ts o_ts, o.dir, o.amt o_amt, o.label,
           e.ref e_ref, e.ts e_ts, e.amt e_amt, e.party, e.note
      from cand2 c join ol o on o.ref = c.o_ref join el e on e.ref = c.e_ref
     where c.rn_o = 1 and c.rn_e = 1
  ),
  /* ── ٣) تسجيل على دفعات: حركة عندنا = حركتين في الخزنة ──── */
  ol3 as (select * from ol where ref not in (select o_ref from m2)),
  el3 as (select * from el where ref not in (select e_ref from m2)),
  pairs as (
    select o.ref o_ref, a.ref e1_ref, b.ref e2_ref,
           round(a.amt + b.amt, 2) tot, abs(o.amt - (a.amt + b.amt)) d,
           row_number() over (partition by o.ref order by abs(o.amt - (a.amt + b.amt))) rn
      from ol3 o
      join el3 a on a.dir = o.dir
      join el3 b on b.dir = o.dir and b.ref > a.ref
     where abs(o.amt - (a.amt + b.amt)) <= 1
  ),
  m3 as (select * from pairs where rn = 1),
  /* ── الباقي ──────────────────────────────────────────────── */
  rest_o as (select * from ol3 where ref not in (select o_ref from m3)),
  rest_e as (select * from el3
              where ref not in (select e1_ref from m3) and ref not in (select e2_ref from m3)),
  rows_all as (
    select o_ts ts, 'ok' state, dir, o_amt ours_amt, e_amt eplus_amt,
           round(o_amt - e_amt, 2) diff, label ours_label, kind,
           jsonb_build_array(jsonb_build_object('ref', e_ref, 'party', party, 'note', note, 'amt', e_amt)) eplus_parts
      from m1
    union all
    select o_ts, 'round', dir, o_amt, e_amt, round(o_amt - e_amt, 2), label, kind,
           jsonb_build_array(jsonb_build_object('ref', e_ref, 'party', party, 'note', note, 'amt', e_amt))
      from m2
    union all
    select o.ts, 'split', o.dir, o.amt, m3.tot, round(o.amt - m3.tot, 2), o.label, o.kind,
           (select jsonb_agg(jsonb_build_object('ref', e.ref, 'party', e.party, 'note', e.note, 'amt', e.amt)
                             order by e.ts)
              from el3 e where e.ref in (m3.e1_ref, m3.e2_ref))
      from m3 join ol3 o on o.ref = m3.o_ref
    union all
    select ts, 'ours_only', dir, amt, null,
           case when dir = 'in' then amt else -amt end, label, kind, '[]'::jsonb
      from rest_o
    union all
    select ts, 'eplus_only', dir, null, amt,
           case when dir = 'in' then -amt else amt end, null, null,
           jsonb_build_array(jsonb_build_object('ref', ref, 'party', party, 'note', note, 'amt', amt))
      from rest_e
  )
  select jsonb_build_object(
    'branch', v_name, 'from', v_from, 'to', v_to,
    'scoped', v_scope is not null,
    'ledger_balance', round(coalesce(v_ledger_bal,0), 2),
    'eplus_balance',  round(v_eplus_bal, 2),
    'eplus_anchor_at', v_anchor_at,
    'balance_diff',   case when v_eplus_bal is null then null
                           else round(v_eplus_bal - coalesce(v_ledger_bal,0), 2) end,
    'net_ours',  (select coalesce(round(sum(case when dir='in' then ours_amt else -ours_amt end),2),0)
                    from rows_all where ours_amt is not null),
    'net_eplus', (select coalesce(round(sum(case when dir='in' then eplus_amt else -eplus_amt end),2),0)
                    from rows_all where eplus_amt is not null),
    'counts', (select jsonb_object_agg(state, n) from (select state, count(*) n from rows_all group by state) q),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
               'ts', ts, 'state', state, 'dir', dir, 'kind', kind,
               'ours_amt', ours_amt, 'eplus_amt', eplus_amt, 'diff', diff,
               'ours_label', ours_label, 'eplus', eplus_parts) order by ts desc), '[]'::jsonb)
             from rows_all)
  ) into v_out;
  return v_out;
end $fn$;

revoke all on function public.get_safe_recon(text, date, date) from public, anon;
grant execute on function public.get_safe_recon(text, date, date) to authenticated;

/* ── التبويب والصلاحيات ───────────────────────────────────────
   ⚠️ الشاشة دي تبويباتها بـ#tab-xxx مش .tab-btn[data-tab] — والـselector
      الغلط معناه تبويب **بلا حارس** يفضل ظاهر لأي دور. اتصلح قبل الدفع.
   شاشة فيها أرقام خزنة ⇒ مقصورة على الأدمن ومدير الفرع افتراضيًا،
   والباقي من شاشة الصلاحيات. الأدوار من القاعدة مش مكتوبة بالإيد. */
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order)
values ('shift_history','saferecon','مطابقة الخزنة','#tab-saferecon', 5)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

insert into public.tab_permissions (page_key, tab_key, role, allowed)
select 'shift_history','saferecon', r.role, (r.role = 'manager')
  from (select distinct role from page_permissions where role <> 'admin') r
on conflict (role, page_key, tab_key) do update set allowed = excluded.allowed;
