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
  /* ٣) المرشّح: فرق قيمة ≤ ٥ ج خلال ساعتين، أو نفس القيمة بعد
        ٢–٢٤ ساعة. **مش مطابقة تلقائية** — المحاسب بيأكد، والإقرار
        بيفضل منسوب لحد (قرار المالك 2026-10-31). */
  openm as (select * from rest r where not exists (select 1 from hit h where h.src=r.src and h.id=r.id)),
  openc as (select * from ct c where not exists (select 1 from hit h where h.fh_id=c.fh_id)),
  candp as (
    select o.src, o.id, c.fh_id, c.channel,
           round(abs(c.amt - o.amt),2) as dv,
           round(abs(extract(epoch from c.ts - o.ts))/60)::int as dm,
           row_number() over (partition by o.src, o.id
             order by abs(c.amt - o.amt), abs(extract(epoch from c.ts - o.ts))) rn_o,
           row_number() over (partition by c.fh_id
             order by abs(c.amt - o.amt), abs(extract(epoch from c.ts - o.ts))) rn_c
      from openm o join openc c on c.bc = o.bc
     where (abs(c.amt - o.amt) <= 5 and abs(extract(epoch from c.ts - o.ts)) <= 7200)
        or (c.amt = o.amt and abs(extract(epoch from c.ts - o.ts)) between 7200 and 86400)
  ),
  cand as (select * from candp where rn_o = 1 and rn_c = 1),
  /* ٤) إثبات المراجعة البشري بيعلو على التصنيف التلقائي */
  rv as (select * from wallet_txn_reviews),
  j as (
    select m.*,
           coalesce(
             case r.kind when 'linked' then 'has_sale' when 'noted' then 'noted'
                         when 'flagged' then 'flagged' end,
             case when c1.out_id is not null or c2.in_id is not null then 'cashout'
                  when h.id is not null then 'has_sale'
                  when cd.fh_id is not null then 'candidate'
                  else 'no_sale' end) as state,
           case r.kind
             when 'linked'  then 'ربط يدوي: بيع ' || r.ref_fh_id::text || ' · ' || r.reviewed_by
             when 'noted'   then coalesce(nullif(r.reason,'') || ' — ', '') || coalesce(r.note,'')
             when 'flagged' then 'مشكلة — ' || r.reviewed_by
             else
               case when c1.out_id is not null then 'تسييل → ماكينة'
                    when c2.in_id  is not null then 'تسييل ← محفظة'
                    when h.id is not null then 'بيع ' || coalesce(h.fh_id::text,'') ||
                                                 coalesce(' · ' || nullif(h.channel,''),'')
                    when cd.fh_id is not null then 'يُحتمل: بيع ' || cd.fh_id::text ||
                         case when cd.dv > 0 then ' · فرق ' || cd.dv::text || ' ج' else '' end ||
                         ' · بفارق ' || cd.dm::text || ' دقيقة'
                    else null end
           end as ev,
           cd.fh_id as cand_fh_id, cd.dv as cand_diff, cd.dm as cand_mins,
           r.kind as rv_kind, r.reviewed_by as rv_by,
           to_char(r.reviewed_at at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI') as rv_at,
           r.note as rv_note, r.reason as rv_reason
      from m
      left join cash c1 on m.src = 'wallet'  and c1.out_id = m.id
      left join cash c2 on m.src = 'machine' and c2.in_id  = m.id
      left join hit  h  on h.src = m.src and h.id = m.id
      left join cand cd on cd.src = m.src and cd.id = m.id
      left join rv   r  on r.src = m.src and r.row_id = m.id
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
                'state', state, 'evidence', ev,
                'cand_fh_id', cand_fh_id, 'cand_diff', cand_diff, 'cand_mins', cand_mins,
                'rv', case when rv_kind is null then null else jsonb_build_object(
                        'kind', rv_kind, 'by', rv_by, 'at', rv_at,
                        'note', rv_note, 'reason', rv_reason) end
              ) order by ts desc, id desc), '[]'::jsonb)
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

/* ════════════════════════════════════════════════════════════════
   إثبات المراجعة + حالة «مرشّح»   (نفس اليوم، بعد سؤال المالك)
   ----------------------------------------------------------------
   سؤاله: «لو المراجع راجع تمام يغلق إزاي؟ وإيه اللي يكون إثبات
   مراجعة؟» — ولو حطّينا زر «تم» عادي نكون رجّعنا نفس العيب اللي
   التبويب ده اتعمل عشانه.

   **القاعدة**: الصف مايتقفلش بضغطة فاضية أبدًا. يتقفل بواحد من:
     🔗 **ربط بمرجع** — رقم بيعة، والسيرفر بيتحقق إنها موجودة في
        نفس الفرع ومش مربوطة بحركة تانية (فهرس فريد على ref_fh_id).
     ✍️ **نص مكتوب** منسوب لصاحبه + سبب مختصر من قائمة (عشان نقدر
        نجمّع الأنماط المتكررة — النص الحر لوحده مابيتجمّعش).
     ⚠️ **مشكلة** — تفضل مفتوحة وحمرا لحد ما تتحل بدل ما تتنسي.

   واللي النظام لقاه بنفسه **مايتكتبش فوقه**: ده واقعة مش رأي، ولو
   خلّيناه قابل للتعديل بيبقى أضعف مش أقوى.

   🔑 **حالة «مرشّح»**: قِسنا الـ«بلا مقابل» فطلع معظمها فلوس ليها
   بيع فعلًا بس نافذة المطابقة ضيّقة — ١١٩ فرق قيمة ≤ ٥ ج خلال
   ساعتين (العميل حوّل ٢٠٧ والفاتورة ٢٠٥)، و١٧١ نفس القيمة بعد
   ٢–٢٤ ساعة. فبدل ما نطلب كتابة دليل ٥٣٤ مرة، النظام بيعرض المرشّح
   صراحة والمحاسب يأكد بضغطة.
   ⚠️ **مرشّح مش مطابقة تلقائية** (اختيار المالك): الربط التلقائي
      بفرق قيمة ممكن يجمع حركتين مختلفتين بالصدفة، **والإقرار لازم
      يفضل منسوب لحد**.

   الأثر: «محتاج شغل بشري» نزل من ٥٣٤ لـ**١٩٢**، و٣٤٥ بقت بضغطة.
   ٧ أيام: ليها بيع ٤٧٩ · مرشّح ٣٤٥ · بلا مقابل ١٩٢ · تسييل ٢.
   ════════════════════════════════════════════════════════════════ */

create table if not exists public.wallet_txn_reviews (
  src         text   not null check (src in ('machine','wallet')),
  row_id      bigint not null,
  branch      text,
  kind        text   not null check (kind in ('linked','noted','flagged')),
  ref_fh_id   bigint,
  reason      text,
  note        text,
  reviewed_by text   not null,
  reviewed_at timestamptz not null default now(),
  primary key (src, row_id)
);
comment on table public.wallet_txn_reviews is
  'إثبات مراجعة حركات الفيزا والمحافظ: ربط بمرجع أو نص منسوب — مش ضغطة «تم»';

/* بيعة واحدة ماتبرّرش حركتين — على مستوى القاعدة مش الشاشة */
create unique index if not exists ux_wallet_review_ref
  on public.wallet_txn_reviews (ref_fh_id) where ref_fh_id is not null;

alter table public.wallet_txn_reviews enable row level security;
drop policy if exists wtr_read on public.wallet_txn_reviews;
create policy wtr_read on public.wallet_txn_reviews for select to authenticated using (true);
revoke all on public.wallet_txn_reviews from public, anon;
grant select on public.wallet_txn_reviews to authenticated;

/* ── تسجيل الإثبات ───────────────────────────────────────────── */
create or replace function public.wallet_review_set(
  p_src text, p_id bigint, p_kind text,
  p_ref_fh_id bigint default null, p_reason text default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_by text; v_branch text; v_role text; v_all boolean; v_scope text;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  if p_src not in ('machine','wallet') then
    raise exception 'مصدر غير معروف' using errcode = '22023';
  end if;

  /* فرع الحركة من مصدرها — مش من الشاشة */
  if p_src = 'machine' then
    select public.branch_code_of(branch) into v_branch from wallet where id = p_id;
  else
    select public.branch_code_of(branch) into v_branch from wallet_sms where id = p_id;
  end if;
  if v_branch is null then
    raise exception 'الحركة غير موجودة' using errcode = 'P0002';
  end if;

  v_role := public.jwt_app_role();
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') <> 'service_role'
     and v_role <> 'admin' then
    select pp.all_branches into v_all from page_permissions pp
     where pp.role = v_role and pp.page_key = 'current_shift';
    if not coalesce(v_all,false) then
      v_scope := public.branch_code_of(public.jwt_branch());
      if v_scope is distinct from v_branch then
        raise exception 'غير مصرّح: الحركة خارج فرعك' using errcode = '42501';
      end if;
    end if;
  end if;

  if p_kind = 'linked' then
    if p_ref_fh_id is null then
      raise exception 'اختر البيعة المقابلة' using errcode = '22023';
    end if;
    if not exists (select 1 from cashier_transactions c
                    where c.fh_id = p_ref_fh_id and c.branch = v_branch
                      and coalesce(c.is_visa,0) = 1) then
      raise exception 'البيعة غير موجودة في نفس الفرع' using errcode = 'P0002';
    end if;
    if exists (select 1 from wallet_txn_reviews w
                where w.ref_fh_id = p_ref_fh_id and not (w.src = p_src and w.row_id = p_id)) then
      raise exception 'البيعة دي مربوطة بحركة تانية بالفعل' using errcode = '23505';
    end if;
  elsif p_kind = 'noted' then
    if coalesce(btrim(p_note),'') = '' then
      raise exception 'اكتب الدليل' using errcode = '22023';
    end if;
  elsif p_kind <> 'flagged' then
    raise exception 'نوع إثبات غير معروف' using errcode = '22023';
  end if;

  v_by := public.bank_actor();
  insert into wallet_txn_reviews (src, row_id, branch, kind, ref_fh_id, reason, note, reviewed_by, reviewed_at)
  values (p_src, p_id, v_branch, p_kind,
          case when p_kind = 'linked' then p_ref_fh_id end,
          nullif(btrim(coalesce(p_reason,'')),''),
          nullif(btrim(coalesce(p_note,'')),''),
          v_by, now())
  on conflict (src, row_id) do update
     set kind = excluded.kind, ref_fh_id = excluded.ref_fh_id,
         reason = excluded.reason, note = excluded.note,
         reviewed_by = excluded.reviewed_by, reviewed_at = excluded.reviewed_at;

  return jsonb_build_object('success', true, 'reviewed_by', v_by,
                            'reviewed_at', to_char(now() at time zone 'Africa/Cairo','HH24:MI'));
end $fn$;

create or replace function public.wallet_review_clear(p_src text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public
as $fn$
begin
  if coalesce(public.jwt_app_role(),'') <> 'admin'
     and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') <> 'service_role' then
    raise exception 'فكّ القفل للأدمن فقط' using errcode = '42501';
  end if;
  delete from wallet_txn_reviews where src = p_src and row_id = p_id;
  return jsonb_build_object('success', true);
end $fn$;

revoke all on function public.wallet_review_set(text, bigint, text, bigint, text, text) from public, anon;
revoke all on function public.wallet_review_clear(text, bigint) from public, anon;
grant execute on function public.wallet_review_set(text, bigint, text, bigint, text, text) to authenticated;
grant execute on function public.wallet_review_clear(text, bigint) to authenticated;

/* ── إعادة تعريف get_wallet_review: حالة «مرشّح» + قراءة الإثبات ──
   ⚠️ بتحلّ محل التعريف اللي فوق في نفس الملف — الترتيب مقصود عشان
      الملف يفضل قابل للتطبيق مرة واحدة من أوله لآخره. */
