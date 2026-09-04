-- ═══════════════════════════════════════════════════════════════════
-- مقارنة السيرفر بالسحابة — استعلام واحد، نتيجة واحدة
-- ═══════════════════════════════════════════════════════════════════
-- (الـSQL Editor بيعرض آخر استعلام بس، فلمّينا كل الفحوص في واحد.)
-- قراءة بس · مش محتاج باسورد (بيستعمل اتصال 'cloud' من خطوة 1).
-- ═══════════════════════════════════════════════════════════════════
with cloud_n as (
  select * from dblink('cloud', $q$
    select
      (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='r'),
      (select count(*) from information_schema.columns where table_schema='public'),
      (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),
      (select count(*) from pg_indexes where schemaname='public'),
      (select count(*) from pg_policies where schemaname='public'),
      (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
        join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal),
      (select count(*) from pg_constraint c join pg_namespace n on n.oid=c.connamespace where n.nspname='public'),
      (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind in ('v','m'))
  $q$) as t(tbls bigint, cols bigint, fns bigint, idx bigint, pol bigint, trg bigint, con bigint, vws bigint)
),
cloud_t as (
  select * from dblink('cloud', $q$
    select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r'
  $q$) as t(relname text)
),
cloud_c as (
  select * from dblink('cloud', $q$
    select c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
    where n.nspname='public' and c.relkind='r'
  $q$) as t(tbl text, col text, typ text)
),
local_c as (
  select c.relname tbl, a.attname col, format_type(a.atttypid, a.atttypmod) typ
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
  where n.nspname='public' and c.relkind='r'
),
diffs as (
  select cc.tbl, cc.col, cc.typ, lc.typ as ltyp
  from cloud_c cc left join local_c lc on lc.tbl=cc.tbl and lc.col=cc.col
  where lc.col is null or lc.typ is distinct from cc.typ
)
select * from (
  -- العدّادات
  select 1 as س, 'جداول'   as البند, c.tbls::text as السحابة,
         (select count(*)::text from pg_class x join pg_namespace n on n.oid=x.relnamespace
           where n.nspname='public' and x.relkind='r') as السيرفر from cloud_n c
  union all select 2, 'أعمدة', c.cols::text,
         (select count(*)::text from information_schema.columns where table_schema='public') from cloud_n c
  union all select 3, 'دوال', c.fns::text,
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public') from cloud_n c
  union all select 4, 'فيوهات', c.vws::text,
         (select count(*)::text from pg_class x join pg_namespace n on n.oid=x.relnamespace
           where n.nspname='public' and x.relkind in ('v','m')) from cloud_n c
  union all select 5, 'فهارس', c.idx::text,
         (select count(*)::text from pg_indexes where schemaname='public') from cloud_n c
  union all select 6, 'سياسات', c.pol::text,
         (select count(*)::text from pg_policies where schemaname='public') from cloud_n c
  union all select 7, 'تريجرات', c.trg::text,
         (select count(*)::text from pg_trigger t join pg_class x on x.oid=t.tgrelid
           join pg_namespace n on n.oid=x.relnamespace where n.nspname='public' and not t.tgisinternal) from cloud_n c
  union all select 8, 'قيود', c.con::text,
         (select count(*)::text from pg_constraint x join pg_namespace n on n.oid=x.connamespace
           where n.nspname='public') from cloud_n c
  -- الفحوص
  union all select 20, '── جداول ناقصة ──',
         (select coalesce(string_agg(ct.relname, ', ' order by ct.relname), '✅ ولا واحد')
          from cloud_t ct where not exists (
            select 1 from pg_class lc join pg_namespace ln on ln.oid=lc.relnamespace
            where ln.nspname='public' and lc.relkind='r' and lc.relname=ct.relname)), ''
  union all select 21, '── أعمدة مختلفة/ناقصة ──', (select count(*)::text from diffs), ''
  -- تفاصيل الأعمدة المختلفة (أول 25)
  union all
  select 30 + row_number() over (order by tbl, col), tbl || '.' || col, typ, coalesce(ltyp, '❌ مش موجود')
  from diffs order by 1 limit 40
) x order by س;
