/* ═══════════════════════════════════════════════════════════════════
   تقييم العملاء برقم الفاتورة — رابط ثابت لكل فرع في رسالة ما بعد الطلب
   ═══════════════════════════════════════════════════════════════════
   ── قرار المالك (2026-10-20) ───────────────────────────────────────
   الصيدلية بتبعت رسالة ثابتة للعميل بعد كل طلب أصلًا. هيتحط فيها رابط
   ثابت **لكل فرع** (rate.html?b=<حرف الفرع>)، والعميل في الصفحة يكتب
   رقم الفاتورة من الريسيت أو يصوّر الباركود اللي أسفله، فتفتح له نفس
   صفحة النجوم للصيدلي والمندوب. مش بديل للدفعة اليومية — مسار إضافي
   بيغطّي أي طلب من غير رسالة مخصوصة.

   ── ليه الفرع في الرابط ───────────────────────────────────────────
   رقم الفاتورة في eplus بيتعدّ لكل فرع لوحده، فنفس الرقم ممكن يبقى
   فاتورتين في فرعين. حرف الفرع (branches.letter) بيفكّ اللبس من غير ما
   نسأل العميل.

   ── التغيير ───────────────────────────────────────────────────────
   • `order_rating_links.source`: 'batch' (الدفعة اليومية) أو 'bill'
     (العميل جه برقم الفاتورة). التقارير بتفرّق بينهم لأن تقييم الدفعة
     أوثق: الرابط اتبعت لعميل محدد، أما رقم الفاتورة فمعاه كل من شاف
     الريسيت.
   • `rating_bill_lookups`: سجل محاولات البحث بالـIP — الدالة العامة
     بتحدّ منها (أرقام الفواتير متسلسلة، فمن غير حد ممكن حد يلفّ على
     الأرقام). الجدول للخدمة بس.
   • دالة `rating_bill_resolve(letter, bill)`: تلاقي الطلب المُوصَّل،
     تعمل/تعيد استخدام صف الرابط، وترجّع توكن جديد. SECURITY DEFINER
     مقصورة على service_role — بتتنادى من Edge بس.
   • مجاميع الشاشة: «روابط أُرسلت» بتعدّ الدفعة بس، وعدد تقييمات
     الفواتير بيتعرض لوحده.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

begin;

alter table public.order_rating_links
  add column if not exists source text not null default 'batch'
  check (source in ('batch','bill'));
create index if not exists orl_bill_branch_idx on public.order_rating_links (branch_id, bill_no);

create table if not exists public.rating_bill_lookups (
  id         bigserial primary key,
  ip         text,
  letter     text,
  bill_no    text,
  ok         boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists rbl_ip_time_idx on public.rating_bill_lookups (ip, created_at desc);
alter table public.rating_bill_lookups enable row level security;
revoke all on public.rating_bill_lookups from anon, authenticated, public;
grant select, insert, delete on public.rating_bill_lookups to service_role;
grant usage, select on sequence public.rating_bill_lookups_id_seq to service_role;

/* تنظيف السجل مع نبضة الكرون (نحتفظ بيومين) */
create or replace function public.rating_batch_tick()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_y date := (now() at time zone 'Africa/Cairo')::date - 1;
        v_h int  := extract(hour from (now() at time zone 'Africa/Cairo'))::int;
        s public.rating_settings%rowtype;
begin
  perform public.require_app_role(array['admin','manager']);
  delete from public.rating_bill_lookups where created_at < now() - interval '2 days';
  select * into s from public.rating_settings where id = 1;
  if v_h < s.batch_hour then
    return jsonb_build_object('skipped', 'before_hour', 'hour', v_h);
  end if;
  if exists (select 1 from public.order_rating_links where batch_date = v_y) then
    update public.order_rating_links set status = 'dropped'
     where status = 'pending' and created_at < now() - make_interval(days => s.unsent_drop_days);
    update public.order_rating_links set status = 'expired'
     where status = 'sent' and expires_at < now();
    return jsonb_build_object('skipped', 'already', 'date', v_y);
  end if;
  return public.rating_generate_batch(v_y);
end $fn$;

/* ── البحث برقم الفاتورة (من Edge بس) ─────────────────────────────
   بترجّع:
     {state:'not_found'}                       مفيش فاتورة بالرقم ده في الفرع
     {state:'not_delivered'}                   الطلب لسه ماتوصّلش (أو ملغي)
     {state:'rated'}                           اتقيّم قبل كده (من أي مسار)
     {state:'open', token, bill_no, delivered_at}  جاهز — التوكن يُستعمل فورًا
   الحد: 20 محاولة/ساعة لكل IP (ناجحة أو فاشلة) → {state:'throttled'}.
   لو كان فيه رابط دفعة مبعوت ولسه مفتوح، التوكن بيتبدّل بالجديد: العميل
   قاعد قدامنا دلوقتي، ورابط الواتساب القديم بيبقى بلا لزوم. */
create or replace function public.rating_bill_resolve(p_letter text, p_bill text, p_ip text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_branch public.branches%rowtype;
  o        record;
  l        public.order_rating_links%rowtype;
  s        public.rating_settings%rowtype;
  v_bill   text := regexp_replace(coalesce(p_bill, ''), '[^0-9]', '', 'g');
  v_token  text;
  v_n      int;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;

  if p_ip is not null then
    select count(*) into v_n from public.rating_bill_lookups
     where ip = p_ip and created_at > now() - interval '1 hour';
    if v_n >= 20 then return jsonb_build_object('state', 'throttled'); end if;
  end if;
  insert into public.rating_bill_lookups (ip, letter, bill_no) values (p_ip, p_letter, v_bill);

  select * into v_branch from public.branches where letter = lower(trim(p_letter)) and is_active limit 1;
  if not found or v_bill = '' then return jsonb_build_object('state', 'not_found'); end if;

  /* الفاتورة ممكن تتكرر لو الطلب اتعاد إنشاؤه — بناخد الأحدث */
  select id, status, delivered_at, driver_id, employee_name, cust_code, customer_name, customer_phone, bill_no
    into o
    from public.orders
   where branch_id = v_branch.id and bill_no = v_bill
   order by created_at desc limit 1;
  if not found then return jsonb_build_object('state', 'not_found'); end if;

  if o.status not in ('delivered','completed') or o.delivered_at is null then
    return jsonb_build_object('state', 'not_delivered');
  end if;

  select * into s from public.rating_settings where id = 1;
  select * into l from public.order_rating_links where order_id = o.id for update;

  if found and l.rated_at is not null then
    return jsonb_build_object('state', 'rated');
  end if;

  v_token := encode(gen_random_bytes(16), 'hex');

  if found then
    update public.order_rating_links
       set status = 'sent', token_hash = encode(digest(v_token, 'sha256'), 'hex'),
           sent_at = coalesce(sent_at, now()), sent_by = coalesce(sent_by, 'العميل برقم الفاتورة'),
           expires_at = now() + make_interval(days => greatest(1, s.link_valid_days)),
           source = case when l.status = 'pending' then 'bill' else l.source end
     where id = l.id;
  else
    insert into public.order_rating_links
      (order_id, batch_date, branch_id, driver_id,
       driver_name, employee_name, cust_code, customer_name, customer_phone, bill_no, delivered_at,
       status, token_hash, sent_at, sent_by, expires_at, source)
    values
      (o.id, (o.delivered_at at time zone 'Africa/Cairo')::date, v_branch.id, o.driver_id,
       (select full_name from public.drivers where id = o.driver_id),
       nullif(trim(o.employee_name), ''), o.cust_code, o.customer_name,
       public.rating_norm_phone(o.customer_phone), o.bill_no, o.delivered_at,
       'sent', encode(digest(v_token, 'sha256'), 'hex'), now(), 'العميل برقم الفاتورة',
       now() + make_interval(days => greatest(1, s.link_valid_days)), 'bill');
  end if;

  update public.rating_bill_lookups set ok = true where id = currval('public.rating_bill_lookups_id_seq');

  return jsonb_build_object('state', 'open', 'token', v_token, 'bill_no', o.bill_no,
                            'delivered_at', o.delivered_at, 'branch', v_branch.name);
end $fn$;

revoke all on function public.rating_bill_resolve(text, text, text) from public, anon, authenticated;
grant execute on function public.rating_bill_resolve(text, text, text) to service_role;

/* ── لوحة الروابط: مسار الفاتورة مش «روابط اتنسخت» — بيتستبعد ─────── */
create or replace function public.rating_links_board(p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_b uuid; v_pending jsonb; v_sent jsonb; v_last jsonb;
begin
  perform public.rating_require_sender();
  v_b := public.rating_scope_branch(p_branch_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'batch_date', l.batch_date, 'customer_name', l.customer_name,
           'phone_masked', left(l.customer_phone, 3) || '•••' || right(l.customer_phone, 4),
           'bill_no', l.bill_no, 'delivered_at', l.delivered_at,
           'driver_name', l.driver_name, 'employee_name', l.employee_name,
           'branch', b.name, 'branch_id', l.branch_id,
           'covers_driver', l.covers_driver, 'covers_employee', l.covers_employee,
           'created_at', l.created_at)
         order by l.batch_date desc, l.id), '[]'::jsonb)
    into v_pending
    from public.order_rating_links l
    left join public.branches b on b.id = l.branch_id
   where l.status = 'pending' and l.source = 'batch'
     and (v_b is null or l.branch_id = v_b);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'batch_date', l.batch_date, 'customer_name', l.customer_name,
           'phone_masked', left(l.customer_phone, 3) || '•••' || right(l.customer_phone, 4),
           'bill_no', l.bill_no, 'branch', b.name,
           'driver_name', l.driver_name, 'employee_name', l.employee_name,
           'status', l.status, 'sent_at', l.sent_at, 'sent_by', l.sent_by,
           'expires_at', l.expires_at, 'opened_at', l.opened_at, 'rated_at', l.rated_at)
         order by l.sent_at desc), '[]'::jsonb)
    into v_sent
    from public.order_rating_links l
    left join public.branches b on b.id = l.branch_id
   where l.status in ('sent','rated','expired') and l.source = 'batch'
     and l.sent_at >= now() - interval '2 days'
     and (v_b is null or l.branch_id = v_b);

  select last_batch into v_last from public.rating_settings where id = 1;

  return jsonb_build_object('pending', v_pending, 'sent', v_sent, 'last_batch', v_last,
                            'scoped_branch', v_b);
end $fn$;

/* ── الترتيب: المؤشرات بتفرّق بين المسارين ─────────────────────── */
create or replace function public.rating_dashboard(p_from date, p_to date, p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_b uuid; v_k jsonb; v_e jsonb; v_d jsonb;
begin
  if public.jwt_app_role() is null
     and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  v_b := public.rating_scope_branch(p_branch_id);

  select jsonb_build_object(
           'sent',       count(*) filter (where l.source = 'batch' and l.sent_at is not null),
           'rated',      count(*) filter (where l.source = 'batch' and l.rated_at is not null),
           'rated_bill', count(*) filter (where l.source = 'bill'  and l.rated_at is not null),
           'avg_employee', round(avg(l.employee_stars)::numeric, 2),
           'avg_driver',   round(avg(l.driver_stars)::numeric, 2))
    into v_k
    from public.order_rating_links l
   where (coalesce(l.rated_at, l.sent_at) at time zone 'Africa/Cairo')::date between p_from and p_to
     and (v_b is null or l.branch_id = v_b);

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_e
    from (select l.employee_name as name, b.name as branch,
                 round(avg(l.employee_stars)::numeric, 2) as avg, count(*) as n,
                 count(*) filter (where l.source = 'bill') as n_bill
            from public.order_rating_links l
            left join public.branches b on b.id = l.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.employee_name, b.name) x;

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_d
    from (select l.driver_id, coalesce(d.full_name, l.driver_name) as name, b.name as branch,
                 round(avg(l.driver_stars)::numeric, 2) as avg, count(*) as n,
                 count(*) filter (where l.source = 'bill') as n_bill
            from public.order_rating_links l
            left join public.drivers d on d.id = l.driver_id
            left join public.branches b on b.id = d.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.driver_id, d.full_name, l.driver_name, b.name) x;

  return jsonb_build_object('kpis', v_k, 'employees', v_e, 'drivers', v_d, 'scoped_branch', v_b);
end $fn$;

/* ── التعليقات: المصدر مع كل صف ───────────────────────────────── */
create or replace function public.rating_comments(p_from date, p_to date, p_branch_id uuid default null,
                                                   p_who text default 'all', p_max_stars int default 5,
                                                   p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_b uuid; v_role text := public.jwt_app_role(); v_total int; v_rows jsonb; v_see boolean;
begin
  select pharmacists_see_comments into v_see from public.rating_settings where id = 1;
  if not (coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
          or v_role in ('admin','manager') or (v_see and v_role is not null)) then
    raise exception 'التعليقات مقصورة على الإدارة' using errcode = '42501';
  end if;
  v_b := public.rating_scope_branch(p_branch_id);

  with f as (
    select l.* from public.order_rating_links l
     where l.rated_at is not null
       and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
       and (v_b is null or l.branch_id = v_b)
       and (p_who = 'all' or (p_who = 'employee' and l.employee_stars <= p_max_stars)
                          or (p_who = 'driver'   and l.driver_stars   <= p_max_stars))
       and (p_who <> 'all' or least(l.employee_stars, l.driver_stars) <= p_max_stars)
  ), pg as (
    select * from f order by rated_at desc
     limit greatest(1, least(200, p_limit)) offset greatest(0, p_offset)
  )
  select (select count(*) from f),
         coalesce((select jsonb_agg(jsonb_build_object(
                     'id', t.id, 'rated_at', t.rated_at, 'bill_no', t.bill_no, 'branch', b.name,
                     'employee_name', t.employee_name, 'employee_stars', t.employee_stars,
                     'driver_name', t.driver_name, 'driver_stars', t.driver_stars, 'comment', t.comment,
                     'source', t.source)
                   order by t.rated_at desc)
                     from pg t left join public.branches b on b.id = t.branch_id), '[]'::jsonb)
    into v_total, v_rows;

  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $fn$;

notify pgrst, 'reload schema';

commit;
