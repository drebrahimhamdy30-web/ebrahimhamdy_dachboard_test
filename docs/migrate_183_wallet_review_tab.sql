/* ════════════════════════════════════════════════════════════════
   تبويب «الفيزا والمحافظ»   (2026-10-31)
   ----------------------------------------------------------------
   **الفرق الجوهري عن تبويب البطاقات**: تبويب البطاقات بيبص من ناحية
   **eplus** — بيراجع اللي اتسجّل. التبويب ده بيبص من ناحية **الفلوس
   نفسها**: كل عملية ماكينة (`wallet`) وكل رسالة محفظة (`wallet_sms`)،
   وفين بيعها. وبالتالي بيمسك اللي **مش في eplus أصلًا** — واللي
   الموظف مش شايفه خالص دلوقتي.

   القياس على ٧ أيام (١٬٠١٥ حركة · ٤٤٦٬٠٨٢ ج):
     🔴 بلا مقابل   ٥٣٤  (١٦٠٬٢٧٤ ج)
     🟢 ليها بيع    ٤٧٩  (٢٢٦٬٧٠٨ ج)
     🔵 تسييل محفظة  ٢   (٥٩٬١٠٠ ج)

   🔑 **التسييل بيتعرف لوحده**: خروج من محفظة («ارسال») ↔ دخول على
   ماكينة بنفس القيمة خلال ٢٤ ساعة. من غير كده المبالغ الكبيرة دي
   كانت هتفضل «بلا مقابل» وتزعّق كل يوم — وده كان تفسير المالك
   للحركات الكبيرة اللي ظهرت في أول فحص.

   ⚠️ الترتيب مهم: **التسييل بيتشال الأول** قبل الربط بالبيع، وإلا
      حركة التسييل ممكن تتربط ببيع بنفس المبلغ بالصدفة.

   ⚠️ المطابقة **واحد لواحد** بالترتيب الزمني جوّه كل (فرع + قيمة) —
      من غير كده بيعة واحدة كانت هتبرّر كذا حركة بنفس المبلغ.

   ⚠️ حارس الفرع على السيرفر (page_permissions.all_branches لصفحة
      current_shift) — إخفاء الفلتر في الشاشة مش حماية.

   الصلاحية: **الأدمن فقط افتراضيًا** زي تبويب البطاقات، والتحكم من
   شاشة الصلاحيات. ⚠️ الـselector بصيغة الشاشة دي (`#tabs .tab
   [data-mode=…]`) مش `#tab-xxx` — الصيغة الغلط = تبويب بلا حارس.

   يتطبّق على: السحابة (اتعمل 2026-10-31) **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.get_wallet_review(
  p_branch text default null, p_from date default null, p_to date default null,
  p_state text default null, p_limit int default 50, p_offset int default 0
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_from date; v_to date; v_lim int; v_off int; v_br text; v_role text; v_all boolean; v_out jsonb;
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
  mv as (
    select 'machine'::text as src, w.id, public.branch_code_of(w.branch) as bc,
           w."createdAt" as ts, round(w.ammount,2) as amt,
           coalesce(w.machine_name, w.terminal_id) as party,
           w.order_id as ref, w.balance, w.type as kind
      from wallet w
     where (w."createdAt" at time zone 'Africa/Cairo')::date between v_from and v_to
    union all
    select 'wallet', s.id, public.branch_code_of(s.branch),
           s."createdAt", round(s.ammount,2), coalesce(s.to_no, s.from_no),
           s.op_ref, s.balance, s.type
      from wallet_sms s
     where (s."createdAt" at time zone 'Africa/Cairo')::date between v_from and v_to
  ),
  m as (select * from mv where v_br is null or bc = v_br),
  ct as (
    select c.branch as bc, c.fh_id, c.actual_date as ts,
           round(case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                      then c.visa_no::numeric else c.amount end, 2) as amt,
           c.channel
      from cashier_transactions c
     where coalesce(c.is_visa,0) = 1
       and (c.actual_date at time zone 'Africa/Cairo')::date between v_from - 1 and v_to + 1
  ),
  outs as (select *, row_number() over (partition by bc, amt order by ts) rk
             from m where src = 'wallet' and kind = 'ارسال'),
  ins  as (select *, row_number() over (partition by bc, amt order by ts) rk
             from m where src = 'machine'),
  cash as (
    select o.id as out_id, i.id as in_id, o.amt
      from outs o join ins i on i.bc = o.bc and i.amt = o.amt and i.rk = o.rk
     where abs(extract(epoch from i.ts - o.ts)) <= 86400
  ),
  rest as (
    select * from m
     where not (src = 'wallet'  and id in (select out_id from cash))
       and not (src = 'machine' and id in (select in_id  from cash))
  ),
  rr as (select *, row_number() over (partition by bc, amt order by ts) rk from rest),
  cr as (select *, row_number() over (partition by bc, amt order by ts) rk from ct),
  hit as (
    select rr.src, rr.id, cr.fh_id, cr.channel
      from rr join cr on cr.bc = rr.bc and cr.amt = rr.amt and cr.rk = rr.rk
     where abs(extract(epoch from cr.ts - rr.ts)) <= 7200
  ),
  j as (
    select m.*,
           case when c1.out_id is not null or c2.in_id is not null then 'cashout'
                when h.id is not null then 'has_sale'
                else 'no_sale' end as state,
           case when c1.out_id is not null then 'تسييل → ماكينة'
                when c2.in_id  is not null then 'تسييل ← محفظة'
                when h.id is not null then 'بيع ' || coalesce(h.fh_id::text,'') ||
                                             coalesce(' · ' || nullif(h.channel,''),'')
                else null end as ev
      from m
      left join cash c1 on m.src = 'wallet'  and c1.out_id = m.id
      left join cash c2 on m.src = 'machine' and c2.in_id  = m.id
      left join hit  h  on h.src = m.src and h.id = m.id
  ),
  f as (select * from j where p_state is null or state = p_state)
  select jsonb_build_object(
    'total',     (select count(*) from f),
    'total_amt', (select coalesce(round(sum(amt)),0) from f),
    'states', (select coalesce(jsonb_object_agg(state, jsonb_build_array(n, v)), '{}'::jsonb)
                 from (select state, count(*) n, round(sum(amt)) v from j group by state) q),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                'src', src, 'id', id, 'branch', bc, 'ts', ts, 'amt', amt,
                'party', party, 'ref', ref, 'balance', balance, 'kind', kind,
                'state', state, 'evidence', ev) order by ts desc, id desc), '[]'::jsonb)
            from (select * from f order by ts desc, id desc limit v_lim offset v_off) p)
  ) into v_out;
  return v_out;
end $fn$;

revoke all on function public.get_wallet_review(text, date, date, text, int, int) from public, anon;
grant execute on function public.get_wallet_review(text, date, date, text, int, int) to authenticated;

/* ── التبويب والصلاحيات ───────────────────────────────────────── */
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order)
values ('current_shift','walletreview','الفيزا والمحافظ','#tabs .tab[data-mode="wallets"]', 6)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

insert into public.tab_permissions (page_key, tab_key, role, allowed)
select 'current_shift','walletreview', r.role, false
  from (select distinct role from page_permissions where role <> 'admin') r
on conflict (role, page_key, tab_key) do update set allowed = excluded.allowed;
