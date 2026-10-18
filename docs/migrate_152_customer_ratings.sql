/* ═══════════════════════════════════════════════════════════════════
   تقييم العملاء للصيادلة ومندوبي التوصيل — رابط لكل طلب
   ═══════════════════════════════════════════════════════════════════
   ── الفكرة ───────────────────────────────────────────────────────
   العميل يقيّم الصيدلي اللي استقبل طلبه (employee_name من فاتورة eplus)
   ومندوب التوصيل (driver_id) من رابط خاص بالطلب. الرابط للطلب مش
   للعميل: كده الرد بيتنسب تلقائيًا للطيار والصيدلي والفرع من غير ما
   العميل يختار حاجة.

   ── الدفعة اليومية (قرار المالك) ─────────────────────────────────
   مش كل طلب بياخد رابط — ده كان هيعمل مئات الرسايل يوميًا من رقم واحد
   وميتا بتحظر على ده. بدل كده: كل يوم الصبح السيستم يختار من **طلبات
   أمس المُوصَّلة** أقل عدد طلبات يغطّي كل طيار وكل صيدلي اشتغل أمس
   (تقييم واحد لكل شخص افتراضيًا — `per_person_daily`). طلب واحد
   بيغطّي طيار وصيدلي معًا فالعدد أقل من مجموع الاتنين. (~30 طيار
   و~30 صيدلي يوميًا على 4 فروع → ~35-50 رابط/يوم).
   • العميل اللي اتبعت له خلال `customer_cooldown_days` يُستبعد،
     والأولوية للعميل الأقدم تقييمًا (أو اللي عمره ما اتقيّم).
   • مدير الفرع **مابيختارش** ولا بيضيف — بيبعت اللي السيستم اختاره.
     لو كان بيختار، التقييم يتحوّل لاختيار العملاء الراضيين.
   • الدفعة بتتولّد بكرون كل ساعة (`rating_batch_tick`) أول ما ساعة
     القاهرة توصل `batch_hour` — مش بكرون على ساعة UTC ثابتة، عشان
     التوقيت الصيفي مايزحزحهاش.

   ── الإرسال اليدوي (قرار المالك) ─────────────────────────────────
   مفيش إرسال أوتوماتيك. اللي بيبعت بيضغط «نسخ الرسالة» فتتنسخ رسالة
   جاهزة فيها الرابط، ويلصقها في واتساب من رقم الفرع. الصف بيتعلّم
   «نُسخت» فورًا ومايتنسخش تاني (الزر بيرفض) — عشان مايتبعتش لنفس
   الطلب مرتين. وفيه «إرجاع» لو النسخ حصل بالغلط.
   **نص الرسالة بيختلف من عميل لآخر**: بيتركّب من 3 أجزاء (تحية ·
   طلب · خاتمة) لكل جزء عدة صيغ، والتركيبة بتتحدد من رقم الرابط.
   مع اسم العميل ورقم الفاتورة والرابط الفريد، مفيش رسالتين متطابقتين
   بتطلع من نفس الرقم — ده مقصود عشان ميتا.

   ── التوكن بيتولّد عند النسخ مش عند التوليد ───────────────────────
   زي رابط المورّد: التوكن **مخزّن مهشّر** (sha256) ومابيطلعش من
   السيرفر غير مرة واحدة. لو كان اتولّد مع الدفعة كنا هنضطر نخزّنه
   صريح عشان الزر يقدر ينسخه بعد ساعات. فبدل كده بيتولّد لحظة الضغط
   على «نسخ»، والصلاحية (3 أيام) بتبدأ من لحظة الإرسال الفعلي — وده
   الأصح للعميل كمان. «إرجاع» بيلغي التوكن القديم نهائيًا.

   ── الأمان ───────────────────────────────────────────────────────
   • الجدولين مقفولين على anon وauthenticated — الوصول عبر RPCs
     SECURITY DEFINER بحراسة الدور، والدالة العامة `order_rating`
     (Edge) بتشتغل بـservice_role. راجع [[anon-key-lockdown]]:
     أي دالة جديدة لازم يتسحب منها PUBLIC وanon صراحةً.
   • `grant ... to service_role` صريح — الـrevoke من public بيسحب اللي
     كان معتمد عليه (فخ رابط المورّد).
   • صفحة العميل بتشوف: اسم المؤسسة، الفرع، رقم الفاتورة، اليوم. **مش
     بتشوف** اسم العميل ولا المبلغ ولا الأصناف ولا اسم الصيدلي/المندوب.
   • التقييم مرة واحدة لكل رابط (409 بعدها).

   ── الشاشة ───────────────────────────────────────────────────────
   ratings.html — 4 تبويبات: الترتيب (للكل) · التعليقات (إدارة) ·
   روابط اليوم (اللي بيبعت) · الإعدادات (أدمن). الترتيب بيعرض المتوسط
   **وعدد التقييمات جنب كل اسم** من غير حد أدنى (قرار المالك: بدل
   إخفاء الأسماء القليلة، نوضّح العدد والقارئ يحكم).

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ⚠️ `link_base` مختلف بين الريبوهين (عنوان GitHub Pages) — بيتظبط
      من تبويب الإعدادات بعد التطبيق.
   ═══════════════════════════════════════════════════════════════════ */

begin;

/* ═══ 1) الإعدادات ═══════════════════════════════════════════════ */
create table if not exists public.rating_settings (
  id                        int primary key default 1 check (id = 1),
  per_person_daily          int  not null default 1,
  customer_cooldown_days    int  not null default 30,
  link_valid_days           int  not null default 3,
  unsent_drop_days          int  not null default 2,
  batch_hour                int  not null default 10,     -- ساعة القاهرة
  pharmacists_see_comments  boolean not null default false,
  link_base                 text not null default 'https://drebrahimhamdy30-web.github.io/ebrahimhamdy_dachboard_test/rate.html?t=',
  msg_greetings             jsonb not null default '["أهلًا {n}،","مساء الخير يا {n}،","{n}، تحية طيبة.","أهلًا بحضرتك يا {n}،","يسعد أوقاتك يا {n}،"]'::jsonb,
  msg_bodies                jsonb not null default '["شكرًا لطلبك من {org} – فرع {b} (فاتورة {inv}). نرجو تقييم تجربتك مع الصيدلي ومندوب التوصيل، الأمر لا يستغرق أكثر من 20 ثانية:","وصلك طلبك من فرع {b} (فاتورة {inv}). رأيك يهمّنا: كيف كان تعامل الصيدلي ومندوب التوصيل؟ قيّمهما من هنا:","بخصوص طلبك رقم {inv} من {org} – {b}: نرجو منك دقيقة لتقييم الصيدلي الذي استقبل طلبك ومندوب التوصيل:","نشكرك على ثقتك في {org}. لو سمحت، قيّم تجربتك في طلب {inv} (فرع {b}) من هذا الرابط:"]'::jsonb,
  msg_tails                 jsonb not null default '["الرابط صالح لمدة {days} أيام. شكرًا لك.","صالح {days} أيام فقط. نقدّر وقتك.","شكرًا لوقتك، الرابط ينتهي بعد {days} أيام.","نتمنى لك دوام الصحة. (الرابط صالح {days} أيام)"]'::jsonb,
  last_batch                jsonb,                         -- ملخّص آخر توليد
  updated_at                timestamptz not null default now(),
  updated_by                text
);
insert into public.rating_settings (id) values (1) on conflict (id) do nothing;

/* ═══ 2) الروابط ═════════════════════════════════════════════════ */
create table if not exists public.order_rating_links (
  id              bigserial primary key,
  order_id        uuid not null unique,                   -- رابط واحد للطلب مدى الحياة
  batch_date      date not null,                          -- يوم التوصيل (قاهرة) اللي الدفعة بتغطّيه
  branch_id       uuid,
  driver_id       uuid,
  driver_name     text,
  employee_name   text,
  cust_code       text,
  customer_name   text,
  customer_phone  text,                                   -- بعد التطبيع 01xxxxxxxxx
  bill_no         text,
  delivered_at    timestamptz,
  covers_driver   boolean not null default false,         -- ليه الطلب ده اتختار
  covers_employee boolean not null default false,
  status          text not null default 'pending'
                  check (status in ('pending','sent','rated','dropped','expired')),
  token_hash      text unique,                            -- sha256 — بيتولّد عند النسخ
  sent_at         timestamptz,
  sent_by         text,
  expires_at      timestamptz,
  opened_at       timestamptz,
  open_count      int not null default 0,
  rated_at        timestamptz,
  driver_stars    smallint check (driver_stars between 1 and 5),
  employee_stars  smallint check (employee_stars between 1 and 5),
  comment         text,
  created_at      timestamptz not null default now()
);
create index if not exists orl_status_batch_idx on public.order_rating_links (status, batch_date);
create index if not exists orl_cust_idx         on public.order_rating_links (cust_code, created_at desc);
create index if not exists orl_branch_idx       on public.order_rating_links (branch_id, batch_date desc);
create index if not exists orl_rated_idx        on public.order_rating_links (rated_at) where rated_at is not null;
create index if not exists orl_sent_idx         on public.order_rating_links (sent_at)  where sent_at  is not null;

/* الجدولين مقفولين تمامًا — الوصول عبر الدوال بس */
alter table public.rating_settings     enable row level security;
alter table public.order_rating_links  enable row level security;
revoke all on public.rating_settings    from anon, authenticated, public;
revoke all on public.order_rating_links from anon, authenticated, public;
grant select, insert, update on public.rating_settings    to service_role;
grant select, insert, update on public.order_rating_links to service_role;
grant usage, select on sequence public.order_rating_links_id_seq to service_role;

/* ═══ 3) مساعدات ═════════════════════════════════════════════════ */

/* تطبيع رقم الموبايل المصري → 01xxxxxxxxx أو null.
   الأرقام في orders بتيجي بأشكال: 010…، 0020 10…، +20 10…، 10… (من غير
   صفر)، وأحيانًا رقمين في خانة واحدة — بناخد أول رقم صالح. */
create or replace function public.rating_norm_phone(p text)
returns text language sql immutable as $fn$
  with d as (
    select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') s
  ), n as (
    select case
             when s ~ '^0020'          then '0' || substr(s, 5)
             when s ~ '^20(1[0-9]{9})' then '0' || substr(s, 3)
             when s ~ '^1[0-9]{9}'     then '0' || s
             else s
           end s
    from d
  )
  select (regexp_match(s, '(01[0-9]{9})'))[1] from n;
$fn$;

/* اسم المستخدم الحالي من التوكن (n8n أو Supabase Auth) */
create or replace function public.rating_jwt_name()
returns text language sql stable as $fn$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'full_name',
    nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'app_metadata' ->> 'full_name',
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'user_name',
    public.jwt_app_role());
$fn$;

/* مين يقدر يبعت الروابط: أدمن/مدير، أو أي دور عنده «تعديل» على الشاشة
   (عشان المالك يقدر يخصّص موظف محدد من شاشة الصلاحيات من غير ترحيل). */
create or replace function public.rating_require_sender()
returns void language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_pg text := coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '');
        v_role text := public.jwt_app_role();
begin
  if v_pg = 'service_role' then return; end if;
  if v_role in ('admin','manager') then return; end if;
  if v_role is not null and exists (
       select 1 from public.page_permissions
        where role = v_role and page in ('ratings','ratings.html') and can_edit) then
    return;
  end if;
  raise exception 'غير مصرّح: إرسال روابط التقييم مقصور على الإدارة' using errcode = '42501';
end $fn$;

/* نطاق الفرع: اللي مايشوفش كل الفروع بيتقيّد بفرعه مهما بعت */
create or replace function public.rating_scope_branch(p_branch_id uuid)
returns uuid language sql stable as $fn$
  select case when public.jwt_all_branches()
              or coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
         then p_branch_id else public.jwt_branch_id() end;
$fn$;

/* ═══ 4) توليد الدفعة اليومية ════════════════════════════════════ */
create or replace function public.rating_generate_batch(p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  s        public.rating_settings%rowtype;
  v_date   date;
  v_ins    int := 0;
  r        record;
  v_out    jsonb;
begin
  perform public.require_app_role(array['admin','manager']);   -- service_role بيعدّي

  select * into s from public.rating_settings where id = 1;
  v_date := coalesce(p_date, (now() at time zone 'Africa/Cairo')::date - 1);

  /* تنظيف: اللي ما اتبعتش في وقته يسقط، واللي اتبعت وفات ميعاده ينتهي */
  update public.order_rating_links
     set status = 'dropped'
   where status = 'pending' and created_at < now() - make_interval(days => s.unsent_drop_days);
  update public.order_rating_links
     set status = 'expired'
   where status = 'sent' and expires_at < now();

  /* الدفعة بتتولّد مرة واحدة لليوم */
  if exists (select 1 from public.order_rating_links where batch_date = v_date) then
    return jsonb_build_object('date', v_date, 'inserted', 0, 'already', true);
  end if;

  drop table if exists rb_cand; drop table if exists rb_need_d; drop table if exists rb_need_e;

  /* المرشّحون: طلبات اليوم المُوصَّلة، بطيار وصيدلي ورقم صالح، عميل
     مش في فترة الراحة، وطلب ماخدش رابط قبل كده */
  create temp table rb_cand on commit drop as
  select o.id as order_id, o.branch_id, o.driver_id, d.full_name as driver_name,
         trim(o.employee_name) as employee_name, o.cust_code, o.customer_name,
         public.rating_norm_phone(o.customer_phone) as phone, o.bill_no, o.delivered_at,
         (select max(l.created_at) from public.order_rating_links l where l.cust_code = o.cust_code) as last_link
    from public.orders o
    join public.drivers d on d.id = o.driver_id
   where o.status in ('delivered','completed')
     and o.delivered_at is not null
     and (o.delivered_at at time zone 'Africa/Cairo')::date = v_date
     and nullif(trim(o.employee_name), '') is not null
     and nullif(trim(o.cust_code), '') is not null
     and public.rating_norm_phone(o.customer_phone) is not null
     and not exists (select 1 from public.order_rating_links l where l.order_id = o.id)
     and not exists (select 1 from public.order_rating_links l
                      where l.cust_code = o.cust_code
                        and l.status in ('pending','sent','rated')
                        and l.created_at > now() - make_interval(days => s.customer_cooldown_days));

  /* الاحتياج: كل طيار اشتغل اليوم، وكل (فرع، صيدلي) */
  create temp table rb_need_d on commit drop as
    select distinct driver_id, s.per_person_daily as need from rb_cand;
  create temp table rb_need_e on commit drop as
    select distinct branch_id, employee_name, s.per_person_daily as need from rb_cand;

  /* تغطية جشعة: كل مرة الطلب اللي بيغطّي أكتر احتياج، وعند التعادل
     العميل الأقدم تقييمًا، ثم عشوائي. عميل واحد = رابط واحد في الدفعة. */
  loop
    select c.*, (nd.need > 0) as cov_d, (ne.need > 0) as cov_e
      into r
      from rb_cand c
      join rb_need_d nd on nd.driver_id = c.driver_id
      join rb_need_e ne on ne.branch_id is not distinct from c.branch_id and ne.employee_name = c.employee_name
     where nd.need > 0 or ne.need > 0
     order by ((nd.need > 0)::int + (ne.need > 0)::int) desc, c.last_link asc nulls first, random()
     limit 1;
    exit when not found;

    insert into public.order_rating_links
      (order_id, batch_date, branch_id, driver_id, driver_name, employee_name, cust_code,
       customer_name, customer_phone, bill_no, delivered_at, covers_driver, covers_employee)
    values
      (r.order_id, v_date, r.branch_id, r.driver_id, r.driver_name, r.employee_name, r.cust_code,
       r.customer_name, r.phone, r.bill_no, r.delivered_at, r.cov_d, r.cov_e);
    v_ins := v_ins + 1;

    update rb_need_d set need = need - 1 where driver_id = r.driver_id and need > 0;
    update rb_need_e set need = need - 1
     where branch_id is not distinct from r.branch_id and employee_name = r.employee_name and need > 0;
    delete from rb_cand where cust_code = r.cust_code;
  end loop;

  v_out := jsonb_build_object(
    'date', v_date, 'inserted', v_ins, 'already', false, 'generated_at', now(),
    'drivers',           (select count(*) from rb_need_d),
    'drivers_covered',   (select count(*) from rb_need_d where need < s.per_person_daily),
    'employees',         (select count(*) from rb_need_e),
    'employees_covered', (select count(*) from rb_need_e where need < s.per_person_daily));

  update public.rating_settings set last_batch = v_out where id = 1;
  return v_out;
end $fn$;

/* نبضة الكرون كل ساعة: لو ساعة القاهرة وصلت ميعاد التوليد ودفعة أمس
   لسه ماتولّدتش → ولّدها. التنظيف بيحصل جوّه التوليد. */
create or replace function public.rating_batch_tick()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_y date := (now() at time zone 'Africa/Cairo')::date - 1;
        v_h int  := extract(hour from now() at time zone 'Africa/Cairo')::int;
        s public.rating_settings%rowtype;
begin
  perform public.require_app_role(array['admin','manager']);
  select * into s from public.rating_settings where id = 1;
  if v_h < s.batch_hour then
    return jsonb_build_object('skipped', 'before_hour', 'hour', v_h);
  end if;
  if exists (select 1 from public.order_rating_links where batch_date = v_y) then
    /* التنظيف بس */
    update public.order_rating_links set status = 'dropped'
     where status = 'pending' and created_at < now() - make_interval(days => s.unsent_drop_days);
    update public.order_rating_links set status = 'expired'
     where status = 'sent' and expires_at < now();
    return jsonb_build_object('skipped', 'already', 'date', v_y);
  end if;
  return public.rating_generate_batch(v_y);
end $fn$;

/* ═══ 5) لوحة الروابط (اللي بيبعت) ═══════════════════════════════ */
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
   where l.status = 'pending'
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
   where l.status in ('sent','rated','expired')
     and l.sent_at >= now() - interval '2 days'
     and (v_b is null or l.branch_id = v_b);

  select last_batch into v_last from public.rating_settings where id = 1;

  return jsonb_build_object('pending', v_pending, 'sent', v_sent, 'last_batch', v_last,
                            'scoped_branch', v_b);
end $fn$;

/* نسخ الرسالة = توليد التوكن + تعليم «نُسخت». بيرفض لو اتنسخ قبل كده. */
create or replace function public.rating_link_copy(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  l       public.order_rating_links%rowtype;
  s       public.rating_settings%rowtype;
  v_token text; v_url text; v_org text; v_branch text; v_first text;
  v_g text; v_bd text; v_t text; v_msg text;
  ng int; nb int; nt int;
begin
  perform public.rating_require_sender();
  select * into l from public.order_rating_links where id = p_id for update;
  if not found then raise exception 'الرابط غير موجود'; end if;
  if l.status = 'sent'  then raise exception 'تم نسخ هذا الرابط بالفعل (بواسطة %)', coalesce(l.sent_by, '—'); end if;
  if l.status <> 'pending' then raise exception 'هذا الرابط لم يعد قابلًا للإرسال (%)', l.status; end if;
  if public.rating_scope_branch(l.branch_id) is distinct from l.branch_id then
    raise exception 'هذا الرابط يخص فرعًا آخر' using errcode = '42501';
  end if;

  select * into s from public.rating_settings where id = 1;
  select company_name into v_org from public.org_settings where id = 1;
  select name into v_branch from public.branches where id = l.branch_id;

  v_token := encode(gen_random_bytes(16), 'hex');          -- 32 حرف
  update public.order_rating_links
     set status = 'sent', token_hash = encode(digest(v_token, 'sha256'), 'hex'),
         sent_at = now(), sent_by = public.rating_jwt_name(),
         expires_at = now() + make_interval(days => greatest(1, s.link_valid_days))
   where id = p_id;

  v_url := s.link_base || v_token;

  /* تركيب الرسالة: الصيغة من رقم الرابط — تركيبة مختلفة لكل عميل */
  ng := greatest(1, jsonb_array_length(s.msg_greetings));
  nb := greatest(1, jsonb_array_length(s.msg_bodies));
  nt := greatest(1, jsonb_array_length(s.msg_tails));
  v_g  := coalesce(s.msg_greetings ->> ((p_id % ng)::int), '');
  v_bd := coalesce(s.msg_bodies    ->> (((p_id * 7) % nb)::int), '');
  v_t  := coalesce(s.msg_tails     ->> (((p_id * 3) % nt)::int), '');
  v_first := coalesce(nullif(split_part(regexp_replace(trim(coalesce(l.customer_name, '')), '^(أ|د|م|ا|أ\.|د\.|م\.|أ/|د/|م/|السيد|السيدة|الدكتور|الدكتورة)\s+', ''), ' ', 1), ''), 'عميلنا العزيز');

  v_msg := concat_ws(E'\n', nullif(v_g, ''), nullif(v_bd, ''), v_url, nullif(v_t, ''));
  v_msg := replace(replace(replace(replace(replace(replace(v_msg,
             '{n}', v_first), '{org}', coalesce(v_org, 'الصيدلية')), '{b}', coalesce(v_branch, '')),
             '{inv}', coalesce(l.bill_no, '')), '{days}', s.link_valid_days::text), '{link}', v_url);

  return jsonb_build_object('id', p_id, 'url', v_url, 'message', v_msg,
                            'expires_at', now() + make_interval(days => s.link_valid_days));
end $fn$;

/* إرجاع رابط اتنسخ بالغلط: يرجع «بانتظار» والتوكن القديم يتلغي */
create or replace function public.rating_link_reset(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare l public.order_rating_links%rowtype;
begin
  perform public.rating_require_sender();
  select * into l from public.order_rating_links where id = p_id for update;
  if not found then raise exception 'الرابط غير موجود'; end if;
  if l.status <> 'sent' then raise exception 'لا يمكن إرجاع رابط حالته «%»', l.status; end if;
  if l.rated_at is not null then raise exception 'العميل قيّم بالفعل من هذا الرابط'; end if;
  if public.rating_scope_branch(l.branch_id) is distinct from l.branch_id then
    raise exception 'هذا الرابط يخص فرعًا آخر' using errcode = '42501';
  end if;
  update public.order_rating_links
     set status = 'pending', token_hash = null, sent_at = null, sent_by = null,
         expires_at = null, opened_at = null, open_count = 0
   where id = p_id;
  return jsonb_build_object('id', p_id, 'status', 'pending');
end $fn$;

/* ═══ 6) الترتيب والمؤشرات (لكل الأدوار اللي عندها الشاشة) ═════════ */
create or replace function public.rating_dashboard(p_from date, p_to date, p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_b uuid; v_k jsonb; v_e jsonb; v_d jsonb;
begin
  if public.jwt_app_role() is null
     and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  v_b := public.rating_scope_branch(p_branch_id);

  /* المؤشرات: روابط اتبعتت في الفترة، وكام منها اتقيّم */
  select jsonb_build_object(
           'sent',  count(*) filter (where l.sent_at is not null),
           'rated', count(*) filter (where l.rated_at is not null),
           'avg_employee', round(avg(l.employee_stars)::numeric, 2),
           'avg_driver',   round(avg(l.driver_stars)::numeric, 2))
    into v_k
    from public.order_rating_links l
   where (l.sent_at at time zone 'Africa/Cairo')::date between p_from and p_to
     and (v_b is null or l.branch_id = v_b);

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_e
    from (select l.employee_name as name, b.name as branch,
                 round(avg(l.employee_stars)::numeric, 2) as avg, count(*) as n
            from public.order_rating_links l
            left join public.branches b on b.id = l.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.employee_name, b.name) x;

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_d
    from (select l.driver_id, coalesce(d.full_name, l.driver_name) as name, b.name as branch,
                 round(avg(l.driver_stars)::numeric, 2) as avg, count(*) as n
            from public.order_rating_links l
            left join public.drivers d on d.id = l.driver_id
            left join public.branches b on b.id = d.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.driver_id, d.full_name, l.driver_name, b.name) x;

  return jsonb_build_object('kpis', v_k, 'employees', v_e, 'drivers', v_d, 'scoped_branch', v_b);
end $fn$;

/* التعليقات النصية: إدارة فقط (أو الصيادلة لو الإعداد مفعّل) — مقسّمة صفحات */
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

  /* الإجمالي على كل الصفوف المفلترة، والصفحة بـlimit/offset */
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
                     'driver_name', t.driver_name, 'driver_stars', t.driver_stars, 'comment', t.comment)
                   order by t.rated_at desc)
                     from pg t left join public.branches b on b.id = t.branch_id), '[]'::jsonb)
    into v_total, v_rows;

  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $fn$;

/* ═══ 7) الإعدادات: قراءة للكل، كتابة للأدمن ═════════════════════ */
create or replace function public.rating_settings_get()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $fn$
  select to_jsonb(s) from public.rating_settings s where id = 1;
$fn$;

create or replace function public.rating_settings_set(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v int;
begin
  perform public.require_app_role(array['admin']);
  if p ? 'per_person_daily' then
    v := (p ->> 'per_person_daily')::int;
    if v < 1 or v > 10 then raise exception 'تقييمات اليوم لكل شخص بين 1 و10'; end if;
    update public.rating_settings set per_person_daily = v where id = 1;
  end if;
  if p ? 'customer_cooldown_days' then
    v := (p ->> 'customer_cooldown_days')::int;
    if v < 1 or v > 365 then raise exception 'فترة الراحة بين 1 و365 يوم'; end if;
    update public.rating_settings set customer_cooldown_days = v where id = 1;
  end if;
  if p ? 'link_valid_days' then
    v := (p ->> 'link_valid_days')::int;
    if v < 1 or v > 30 then raise exception 'صلاحية الرابط بين 1 و30 يوم'; end if;
    update public.rating_settings set link_valid_days = v where id = 1;
  end if;
  if p ? 'unsent_drop_days' then
    v := (p ->> 'unsent_drop_days')::int;
    if v < 1 or v > 30 then raise exception 'سقوط الرابط بين 1 و30 يوم'; end if;
    update public.rating_settings set unsent_drop_days = v where id = 1;
  end if;
  if p ? 'batch_hour' then
    v := (p ->> 'batch_hour')::int;
    if v < 0 or v > 23 then raise exception 'ساعة التوليد بين 0 و23'; end if;
    update public.rating_settings set batch_hour = v where id = 1;
  end if;
  if p ? 'pharmacists_see_comments' then
    update public.rating_settings set pharmacists_see_comments = (p ->> 'pharmacists_see_comments')::boolean where id = 1;
  end if;
  if p ? 'link_base' then
    if (p ->> 'link_base') !~ '^https://' then raise exception 'رابط الصفحة لازم يبدأ بـhttps://'; end if;
    update public.rating_settings set link_base = p ->> 'link_base' where id = 1;
  end if;
  if p ? 'msg_greetings' then
    if jsonb_typeof(p -> 'msg_greetings') <> 'array' or jsonb_array_length(p -> 'msg_greetings') = 0 then raise exception 'صيغ التحية لازم تكون قائمة فيها صيغة واحدة على الأقل'; end if;
    update public.rating_settings set msg_greetings = p -> 'msg_greetings' where id = 1;
  end if;
  if p ? 'msg_bodies' then
    if jsonb_typeof(p -> 'msg_bodies') <> 'array' or jsonb_array_length(p -> 'msg_bodies') = 0 then raise exception 'صيغ الطلب لازم تكون قائمة فيها صيغة واحدة على الأقل'; end if;
    update public.rating_settings set msg_bodies = p -> 'msg_bodies' where id = 1;
  end if;
  if p ? 'msg_tails' then
    if jsonb_typeof(p -> 'msg_tails') <> 'array' or jsonb_array_length(p -> 'msg_tails') = 0 then raise exception 'صيغ الخاتمة لازم تكون قائمة فيها صيغة واحدة على الأقل'; end if;
    update public.rating_settings set msg_tails = p -> 'msg_tails' where id = 1;
  end if;
  update public.rating_settings set updated_at = now(), updated_by = public.rating_jwt_name() where id = 1;
  return public.rating_settings_get();
end $fn$;

/* ═══ 8) الصلاحيات على الدوال ════════════════════════════════════ */
revoke all on function public.rating_norm_phone(text)                                              from public, anon;
revoke all on function public.rating_jwt_name()                                                    from public, anon;
revoke all on function public.rating_require_sender()                                              from public, anon;
revoke all on function public.rating_scope_branch(uuid)                                            from public, anon;
revoke all on function public.rating_generate_batch(date)                                          from public, anon;
revoke all on function public.rating_batch_tick()                                                  from public, anon;
revoke all on function public.rating_links_board(uuid)                                             from public, anon;
revoke all on function public.rating_link_copy(bigint)                                             from public, anon;
revoke all on function public.rating_link_reset(bigint)                                            from public, anon;
revoke all on function public.rating_dashboard(date, date, uuid)                                   from public, anon;
revoke all on function public.rating_comments(date, date, uuid, text, int, int, int)               from public, anon;
revoke all on function public.rating_settings_get()                                                from public, anon;
revoke all on function public.rating_settings_set(jsonb)                                           from public, anon;

grant execute on function public.rating_norm_phone(text)                                           to authenticated, service_role;
grant execute on function public.rating_jwt_name()                                                 to authenticated, service_role;
grant execute on function public.rating_require_sender()                                           to authenticated, service_role;
grant execute on function public.rating_scope_branch(uuid)                                         to authenticated, service_role;
grant execute on function public.rating_generate_batch(date)                                       to authenticated, service_role;
grant execute on function public.rating_batch_tick()                                               to authenticated, service_role;
grant execute on function public.rating_links_board(uuid)                                          to authenticated, service_role;
grant execute on function public.rating_link_copy(bigint)                                          to authenticated, service_role;
grant execute on function public.rating_link_reset(bigint)                                         to authenticated, service_role;
grant execute on function public.rating_dashboard(date, date, uuid)                                to authenticated, service_role;
grant execute on function public.rating_comments(date, date, uuid, text, int, int, int)            to authenticated, service_role;
grant execute on function public.rating_settings_get()                                             to authenticated, service_role;
grant execute on function public.rating_settings_set(jsonb)                                        to authenticated, service_role;

/* ═══ 9) تسجيل الشاشة والتبويبات ════════════════════════════════ */
insert into public.app_pages (key, file, title, section, sort_order, is_active)
values ('ratings', 'ratings.html', 'تقييم العملاء', 'التوصيل', 335, true)
on conflict (key) do update set file = excluded.file, title = excluded.title,
  section = excluded.section, sort_order = excluded.sort_order, is_active = true;

/* العرض: الإدارة والصيادلة. التعديل (= إرسال الروابط): الإدارة. */
insert into public.page_permissions (role, page, can_view, can_edit)
select r, 'ratings.html', true, r in ('admin','manager')
  from unnest(array['admin','manager','pharmacist','supervisor']) r
on conflict (role, page) do update set can_view = true, can_edit = excluded.can_edit;

insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order) values
  ('ratings', 'rank',     'الترتيب',      '#tabs .tab[data-tk="rank"]',     1),
  ('ratings', 'comments', 'التعليقات',    '#tabs .tab[data-tk="comments"]', 2),
  ('ratings', 'links',    'روابط اليوم',  '#tabs .tab[data-tk="links"]',    3),
  ('ratings', 'settings', 'الإعدادات',    '#tabs .tab[data-tk="settings"]', 4)
on conflict (page_key, tab_key) do update set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

/* الصيادلة والمشرفون: الترتيب بس. (الأدمن بيعدّي دايمًا؛ المدير مسموح له الكل) */
insert into public.tab_permissions (role, page_key, tab_key, allowed)
select r, 'ratings', t, false
  from unnest(array['pharmacist','supervisor','employee','cashier','accountant','inventory','reviewer']) r,
       unnest(array['comments','links','settings']) t
on conflict (role, page_key, tab_key) do nothing;

/* ═══ 10) الكرون: نبضة كل ساعة (الدقيقة 5) ═══════════════════════ */
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'rating_batch_hourly';
    perform cron.schedule('rating_batch_hourly', '5 * * * *', $cron$ select public.rating_batch_tick(); $cron$);
  else
    raise notice 'pg_cron مش موجود — شغّل rating_batch_tick() من n8n كل ساعة';
  end if;
end $do$;

notify pgrst, 'reload schema';

commit;
