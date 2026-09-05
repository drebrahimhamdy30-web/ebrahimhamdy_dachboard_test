-- ═══════════════════════════════════════════════════════════════════
-- خطوة 8: إعادة بناء طبقة الأمان على السيرفر من السحابة
-- ═══════════════════════════════════════════════════════════════════
-- التدقيق طلّع: 855 صلاحية anon زيادة (منها 492 كتابة) · 91 سياسة
-- بتشمل anon · 6 جداول RLS مقفول.
--
-- ⚠️ السبب مش النقل: الجداول كانت متعمولة على السيرفر من محاولة سابقة
--    **وقت ما السحابة كانت لسه مفتوحة**. فـ`create policy` بتاع النقل
--    فشل بـ«موجود بالفعل» وسـاب السياسات القديمة المتساهلة مكانها.
--    والصلاحيات جت من `alter default privileges` بتاع تنصيبة Supabase
--    المستضافة اللي بتدّي anon كل جدول جديد تلقائيًا.
--
-- ⚠️ الدرس: نقل الصلاحيات مش كفاية — لازم **تمسح القديم الأول**، وإلا
--    بتضيف فوق وضع متساهل بدل ما تستبدله. و«موجود بالفعل» مش نجاح.
--
-- الملف ده: يمسح كل سياسات وصلاحيات anon في public، ويعيد بناءها من
-- حالة السحابة الحالية. آمن للتشغيل المتكرر.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

-- ── 1) امسح القديم ──────────────────────────────────────────────
do $wipe$
declare r record; n int := 0;
begin
  -- كل السياسات في public (هنعيد بناءها من السحابة)
  for r in select tablename, policyname from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
    n := n + 1;
  end loop;
  raise notice 'اتمسحت % سياسة', n;

  -- كل صلاحيات anon على جداول وفيوهات public
  n := 0;
  for r in select c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
           where ns.nspname = 'public' and c.relkind in ('r','v','m','p') loop
    execute format('revoke all on public.%I from anon', r.relname);
    n := n + 1;
  end loop;
  raise notice 'اتسحبت صلاحيات anon من % كائن', n;
end $wipe$;

-- ⚠️ ومنع التنصيبة من إعطاء anon أي جدول **جديد** تلقائيًا بعد كده
alter default privileges in schema public revoke all on tables from anon;

-- ── 2) فعّل RLS زي السحابة ──────────────────────────────────────
do $rls$
declare r record; n int := 0;
begin
  for r in select ddl from cloudsrc.v_migration_ddl where kind = 'rls' loop
    begin execute r.ddl; n := n + 1; exception when others then null; end;
  end loop;
  raise notice 'RLS اتفعّل على % جدول', n;
end $rls$;

-- ── 3) أعد بناء السياسات والصلاحيات من السحابة ──────────────────
do $rebuild$
declare r record; n_ok int := 0; n_err int := 0; last_err text := '';
begin
  for r in select ord, kind, obj, ddl from cloudsrc.v_migration_ddl
           where kind in ('policy','grant','fn_acl') order by ord, obj
  loop
    begin
      execute r.ddl;
      n_ok := n_ok + 1;
    exception when others then
      n_err := n_err + 1;
      last_err := r.kind || '/' || r.obj || ' → ' || left(sqlerrm, 100);
    end;
  end loop;
  raise notice 'اتبنى %: نجح % / فشل %  %', 'الأمان', n_ok, n_err,
               case when n_err > 0 then '(آخر خطأ: ' || last_err || ')' else '' end;
end $rebuild$;

-- ── 4) إعادة التدقيق ────────────────────────────────────────────
with cloud_g as (
  select * from dblink('cloud', $q$
    select g.table_name, g.privilege_type from information_schema.role_table_grants g
    where g.table_schema='public' and g.grantee='anon'
  $q$) as t(tbl text, priv text)
),
local_g as (
  select table_name tbl, privilege_type priv from information_schema.role_table_grants
  where table_schema='public' and grantee='anon'
),
extra as (select l.tbl, l.priv from local_g l
          where not exists (select 1 from cloud_g c where c.tbl=l.tbl and c.priv=l.priv)),
missing as (select c.tbl, c.priv from cloud_g c
            where not exists (select 1 from local_g l where l.tbl=c.tbl and l.priv=c.priv))
select * from (
  select 1 as س, 'صلاحيات anon زيادة عن السحابة' as البند, count(*)::text as العدد,
         coalesce(string_agg(distinct tbl, ', ' order by tbl), '✅ ولا واحدة') as التفاصيل from extra
  union all
  select 2, 'منها كتابة', count(*)::text,
         coalesce(string_agg(distinct tbl, ', ' order by tbl), '✅ ولا واحدة')
  from extra where priv in ('INSERT','UPDATE','DELETE','TRUNCATE')
  union all
  select 3, 'صلاحيات ناقصة عن السحابة', (select count(*)::text from missing),
         (select coalesce(string_agg(distinct tbl, ', ' order by tbl), '✅ ولا واحدة') from missing)
  union all
  select 4, 'جداول RLS مقفول',
         (select count(*)::text from pg_class c join pg_namespace n on n.oid=c.relnamespace
          where n.nspname='public' and c.relkind='r' and not c.relrowsecurity),
         (select coalesce(string_agg(c.relname, ', ' order by c.relname), '✅ ولا واحد')
          from pg_class c join pg_namespace n on n.oid=c.relnamespace
          where n.nspname='public' and c.relkind='r' and not c.relrowsecurity)
  union all
  select 5, 'سياسات بتشمل anon/public',
         (select count(*)::text from pg_policies where schemaname='public'
            and ('anon'=any(roles::text[]) or 'public'=any(roles::text[]))),
         (select coalesce(string_agg(distinct tablename, ', ' order by tablename), '✅ ولا واحدة')
          from pg_policies where schemaname='public'
            and ('anon'=any(roles::text[]) or 'public'=any(roles::text[])))
) x order by س;
