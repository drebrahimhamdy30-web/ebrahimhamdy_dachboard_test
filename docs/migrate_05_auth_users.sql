-- ═══════════════════════════════════════════════════════════════════
-- خطوة 5: نقل حسابات الدخول (80 مستخدم بالباسوردات)
-- ═══════════════════════════════════════════════════════════════════
-- بينقل auth.users و auth.identities بس.
--
-- ⚠️ **الجلسات والـrefresh tokens مش بتتنقل عن قصد** — مربوطة بمفتاح
--    JWT بتاع السحابة، والسيرفر مفتاحه مختلف. الكل هيسجّل دخول مرة
--    واحدة على السيرفر الجديد وخلاص. نقلها كان هيدّي جلسات ميتة.
--
-- ⚠️ فخ حقيقي وقعت فيه قبل كده: GoTrue بيقرا أعمدة التوكن
--    (confirmation_token, recovery_token, email_change*, phone_change*,
--    reauthentication_token) كنص **مش nullable**. أي NULL فيها بيخلّي
--    **تسجيل الدخول كله** يرجّع «500 Database error querying schema» —
--    مش المستخدم ده بس، الكل. السكربت بيحوّل أي NULL لـ'' احتياطًا.
--    (على السحابة كلها '' فعلًا، بس السيرفر ممكن يكون إصدار GoTrue
--     مختلف بأعمدة زيادة قيمتها NULL افتراضيًا.)
--
-- ⚠️ بننقل **تقاطع الأعمدة** بين السحابة والسيرفر بس — إصدارات GoTrue
--    بتختلف في الأعمدة، ونسخ عمود مش موجود بيوقف كل حاجة.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

-- ── 1) جداول auth من السحابة ────────────────────────────────────
drop schema if exists cloudauth cascade;
create schema cloudauth;
import foreign schema auth limit to (users, identities) from server cloud into cloudauth;

-- ── 2) النقل ────────────────────────────────────────────────────
do $auth$
declare
  cols_u text;
  sel_u  text;
  cols_i text;
  n      bigint;
  -- الأعمدة اللي GoTrue بيقراها كنص مش nullable
  guard  text[] := array['confirmation_token','recovery_token','email_change_token_new',
                         'email_change','email_change_token_current','phone_change',
                         'phone_change_token','reauthentication_token'];
begin
  -- تقاطع أعمدة users (السحابة ∩ السيرفر)
  -- ⚠️ **ناقص الأعمدة المولّدة**: auth.users فيها confirmed_at وهو
  --    generated always as (least(email_confirmed_at, phone_confirmed_at))
  --    — Postgres بيحسبه لوحده ومابيقبلش قيمة صريحة بأي طريقة.
  select string_agg(quote_ident(c.attname), ', ' order by c.attnum),
         string_agg(
           case when c.attname = any(guard)
                then format('coalesce(%I, '''')', c.attname)
                else quote_ident(c.attname) end, ', ' order by c.attnum)
    into cols_u, sel_u
  from pg_attribute c
  join pg_class cc on cc.oid = c.attrelid
  join pg_namespace cn on cn.oid = cc.relnamespace
  where cn.nspname = 'cloudauth' and cc.relname = 'users'
    and c.attnum > 0 and not c.attisdropped
    and exists (select 1 from pg_attribute la join pg_class lc on lc.oid = la.attrelid
                join pg_namespace ln on ln.oid = lc.relnamespace
                where ln.nspname = 'auth' and lc.relname = 'users'
                  and la.attname = c.attname and la.attnum > 0 and not la.attisdropped
                  and la.attgenerated = '');

  execute format(
    'insert into auth.users (%s) select %s from cloudauth.users
       on conflict (id) do nothing', cols_u, sel_u);
  get diagnostics n = row_count;
  raise notice 'users: %', n;

  -- identities
  select string_agg(quote_ident(c.attname), ', ' order by c.attnum) into cols_i
  from pg_attribute c
  join pg_class cc on cc.oid = c.attrelid
  join pg_namespace cn on cn.oid = cc.relnamespace
  where cn.nspname = 'cloudauth' and cc.relname = 'identities'
    and c.attnum > 0 and not c.attisdropped
    and exists (select 1 from pg_attribute la join pg_class lc on lc.oid = la.attrelid
                join pg_namespace ln on ln.oid = lc.relnamespace
                where ln.nspname = 'auth' and lc.relname = 'identities'
                  and la.attname = c.attname and la.attnum > 0 and not la.attisdropped
                  and la.attgenerated = '');   -- نفس السبب: أعمدة مولّدة

  execute format(
    'insert into auth.identities (%s) select %s from cloudauth.identities
       on conflict do nothing', cols_i, cols_i);
  get diagnostics n = row_count;
  raise notice 'identities: %', n;
end $auth$;

-- ── 3) حارس: أي NULL في أعمدة التوكن يكسر الدخول للكل ───────────
update auth.users set
  confirmation_token         = coalesce(confirmation_token, ''),
  recovery_token             = coalesce(recovery_token, ''),
  email_change_token_new     = coalesce(email_change_token_new, ''),
  email_change               = coalesce(email_change, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change               = coalesce(phone_change, ''),
  phone_change_token         = coalesce(phone_change_token, ''),
  reauthentication_token     = coalesce(reauthentication_token, '')
where confirmation_token is null or recovery_token is null
   or email_change_token_new is null or email_change is null
   or email_change_token_current is null or phone_change is null
   or phone_change_token is null or reauthentication_token is null;

-- ── 4) التحقق ───────────────────────────────────────────────────
select
  (select count(*) from auth.users)                                          as مستخدمين,
  (select count(*) from auth.identities)                                     as هويات,
  (select count(*) from auth.users
     where encrypted_password is not null and encrypted_password <> '')       as بباسورد,
  (select count(*) from auth.users
     where (raw_app_meta_data->>'branch_user_id') is not null)                as مربوطين_بالفروع,
  (select count(*) from auth.users u
     where exists (select 1 from public.branch_users b
                   where b.id = (u.raw_app_meta_data->>'branch_user_id')::int)) as الربط_سليم;
