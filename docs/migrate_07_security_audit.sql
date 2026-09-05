-- ═══════════════════════════════════════════════════════════════════
-- خطوة 7: تدقيق أمني على السيرفر — هل الإغلاق انتقل فعلًا؟
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ اكتُشف إن `sales_items` بترجّع بيانات لمفتاح anon على السيرفر،
--    رغم إنها مقفولة على السحابة. السبب الأرجح: Supabase المستضاف عنده
--    **صلاحيات افتراضية** (`alter default privileges`) بتدّي anon كل
--    جدول جديد تلقائيًا — فالجداول اللي السكربت أنشأها ورثتها.
--
--    يعني نقل الصلاحيات مش كفاية: لازم **نسحب** اللي زيادة كمان.
--
-- الملف ده **بيقيس بس** ومابيغيّرش حاجة. الإصلاح في الخطوة اللي بعدها.
-- ═══════════════════════════════════════════════════════════════════

with cloud_g as (
  select * from dblink('cloud', $q$
    select g.table_name, g.privilege_type
    from information_schema.role_table_grants g
    where g.table_schema='public' and g.grantee='anon'
  $q$) as t(tbl text, priv text)
),
local_g as (
  select g.table_name as tbl, g.privilege_type as priv
  from information_schema.role_table_grants g
  where g.table_schema='public' and g.grantee='anon'
),
extra as (   -- صلاحيات على السيرفر مش موجودة على السحابة = زيادة خطرة
  select l.tbl, l.priv from local_g l
  where not exists (select 1 from cloud_g c where c.tbl=l.tbl and c.priv=l.priv)
),
pol as (     -- سياسات بتشمل anon/public على السيرفر
  select tablename, policyname from pg_policies
  where schemaname='public' and ('anon'=any(roles::text[]) or 'public'=any(roles::text[]))
),
norls as (   -- جداول من غير RLS على السيرفر
  select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r' and not c.relrowsecurity
)
select * from (
  select 1 as س, 'صلاحيات anon زيادة (جدول/صلاحية)' as البند, count(*)::text as العدد,
         coalesce(string_agg(distinct tbl, ', ' order by tbl), '✅ ولا واحد') as التفاصيل
  from extra
  union all
  select 2, 'منها كتابة (INSERT/UPDATE/DELETE)', count(*)::text,
         coalesce(string_agg(distinct tbl, ', ' order by tbl), '✅ ولا واحد')
  from extra where priv in ('INSERT','UPDATE','DELETE','TRUNCATE')
  union all
  select 3, 'جداول RLS مقفول', (select count(*)::text from norls),
         (select coalesce(string_agg(relname, ', ' order by relname), '✅ ولا واحد') from norls)
  union all
  select 4, 'سياسات بتشمل anon/public', (select count(*)::text from pol),
         (select coalesce(string_agg(distinct tablename, ', ' order by tablename), '✅ ولا واحدة') from pol)
  union all
  select 5, 'دوال anon ينفّذها وبتلمس بيانات مالية',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and has_function_privilege('anon',p.oid,'EXECUTE')
            and p.prosrc ~ '\m(contracts|sales_items|erp_expenses|pos_shifts|pos_wallet_transfers|wallet)\M'),
         (select coalesce(string_agg(p.proname, ', '), '✅ ولا واحدة')
          from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and has_function_privilege('anon',p.oid,'EXECUTE')
            and p.prosrc ~ '\m(contracts|sales_items|erp_expenses|pos_shifts|pos_wallet_transfers|wallet)\M')
) x order by س;
