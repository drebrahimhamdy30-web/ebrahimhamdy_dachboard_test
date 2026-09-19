-- ═══════════════════════════════════════════════════════════════════
--  مزامنة حسابات الدخول من السحابة (إضافة الجديد + تحديث المتغيّر)
-- ═══════════════════════════════════════════════════════════════════
--  migrate_05 نقل الـ80 حساب مرة واحدة بـ«on conflict do nothing» —
--  يعني بيضيف الناقص ومابيلمسش الموجود. المشكلة إن الحساب الموجود
--  بيتغيّر: الباسورد يتبدّل، و**الدور** (app_metadata.user_role) يتعدّل
--  من شاشة الحسابات. والدور هو أساس كل الصلاحيات — لو قديم على
--  السيرفر، المستخدم يشوف حاجات مالوش حق فيها أو العكس.
--
--  فده بيعمل الاتنين: يضيف الجديد، ويحدّث اللي updated_at بتاعه اتغيّر.
--
--  بيقرا من السحابة عبر cloudauth (postgres_fdw) وبيتعامل مع:
--    • تقاطع الأعمدة بين الجهتين (إصدارات GoTrue بتختلف)
--    • الأعمدة المولّدة (confirmed_at) — Postgres بيرفض كتابتها
--    • أعمدة التوكن اللي NULL فيها **بتكسّر تسجيل الدخول للكل**
--      برسالة «500 Database error querying schema» — مش للمستخدم ده بس
--
--  ⚠️ الجلسات مش بتتنقل عن قصد: مربوطة بختم JWT بتاع السحابة والسيرفر
--     ختمه مختلف. كل واحد هيسجّل دخول مرة على السيرفر وخلاص.
--
--  التشغيل:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/refresh_auth_users.sql
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

drop schema if exists cloudauth cascade;
create schema cloudauth;
import foreign schema auth limit to (users, identities) from server cloud into cloudauth;

do $auth$
declare
  cols_u text; sel_u text; set_u text; cols_i text;
  n_ins bigint := 0; n_upd bigint := 0; n_idn bigint := 0;
  guard constant text[] := array[
    'confirmation_token','recovery_token','email_change_token_new',
    'email_change','email_change_token_current','phone_change',
    'phone_change_token','reauthentication_token'];
begin
  -- ── أعمدة users: التقاطع، من غير المولّدة ────────────────────────
  select string_agg(quote_ident(c.attname), ', ' order by c.attnum),
         string_agg(case when c.attname = any(guard)
                         then format('coalesce(%I, '''')', c.attname)
                         else quote_ident(c.attname) end, ', ' order by c.attnum),
         string_agg(case when c.attname = 'id' then null
                         when c.attname = any(guard)
                         then format('%I = coalesce(c.%I, '''')', c.attname, c.attname)
                         else format('%I = c.%I', c.attname, c.attname) end, ', ' order by c.attnum)
    into cols_u, sel_u, set_u
  from pg_attribute c
  join pg_class cc on cc.oid = c.attrelid
  join pg_namespace cn on cn.oid = cc.relnamespace
  where cn.nspname = 'cloudauth' and cc.relname = 'users'
    and c.attnum > 0 and not c.attisdropped
    and exists (select 1 from pg_attribute la
                join pg_class lc on lc.oid = la.attrelid
                join pg_namespace ln on ln.oid = lc.relnamespace
                where ln.nspname = 'auth' and lc.relname = 'users'
                  and la.attname = c.attname and la.attnum > 0
                  and not la.attisdropped and la.attgenerated = '');

  -- ── الجديد ───────────────────────────────────────────────────────
  execute format('insert into auth.users (%s) select %s from cloudauth.users
                  on conflict (id) do nothing', cols_u, sel_u);
  get diagnostics n_ins = row_count;

  -- ── المتغيّر (الباسورد أو الدور أو الإيميل) ───────────────────────
  execute format('update auth.users u set %s from cloudauth.users c
                  where c.id = u.id and c.updated_at is distinct from u.updated_at', set_u);
  get diagnostics n_upd = row_count;

  -- ── الهويات ──────────────────────────────────────────────────────
  select string_agg(quote_ident(c.attname), ', ' order by c.attnum) into cols_i
  from pg_attribute c
  join pg_class cc on cc.oid = c.attrelid
  join pg_namespace cn on cn.oid = cc.relnamespace
  where cn.nspname = 'cloudauth' and cc.relname = 'identities'
    and c.attnum > 0 and not c.attisdropped
    and exists (select 1 from pg_attribute la
                join pg_class lc on lc.oid = la.attrelid
                join pg_namespace ln on ln.oid = lc.relnamespace
                where ln.nspname = 'auth' and lc.relname = 'identities'
                  and la.attname = c.attname and la.attnum > 0
                  and not la.attisdropped and la.attgenerated = '');

  execute format('insert into auth.identities (%s) select %s from cloudauth.identities
                  on conflict do nothing', cols_i, cols_i);
  get diagnostics n_idn = row_count;

  raise notice '═══ حسابات جديدة: %  ·  اتحدّثت: %  ·  هويات جديدة: % ═══',
    n_ins, n_upd, n_idn;
end $auth$;

-- ── حارس: NULL في أي عمود توكن بيكسّر الدخول للكل ────────────────
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

-- ── التحقق ───────────────────────────────────────────────────────
select
  (select count(*) from auth.users)                     as "حسابات",
  (select count(*) from cloudauth.users)                as "على_السحابة",
  (select count(*) from auth.identities)                as "هويات",
  (select count(*) from auth.users
    where encrypted_password is not null
      and encrypted_password <> '')                     as "بباسورد",
  (select count(*) from auth.users
    where (raw_app_meta_data->>'user_role') is not null) as "بدور",
  (select count(*) from auth.users u
    where exists (select 1 from public.branch_users b
                  where b.id = (u.raw_app_meta_data->>'branch_user_id')::int)) as "ربط_سليم";

-- الأدوار: لازم تطابق السحابة عددًا
-- (بنجمّع كل ناحية لوحدها وبعدين نقارن — المقارنة جوّه group by
--  بتدي: subquery uses ungrouped column)
with srv as (
  select coalesce(raw_app_meta_data->>'user_role', '(بلا دور)') as role, count(*) as n
  from auth.users group by 1
), cld as (
  select coalesce(raw_app_meta_data->>'user_role', '(بلا دور)') as role, count(*) as n
  from cloudauth.users group by 1
)
select coalesce(s.role, c.role) as "الدور",
       coalesce(s.n, 0) as "على السيرفر",
       coalesce(c.n, 0) as "على السحابة",
       case when coalesce(s.n,0) = coalesce(c.n,0) then '✓' else '⚠️ فرق' end as "الحالة"
from srv s full join cld c on c.role = s.role
order by 2 desc;
