-- ═══════════════════════════════════════════════════════════════════
-- خطوة 2: هل السكيما على السيرفر مطابقة للسحابة فعلًا؟
-- ═══════════════════════════════════════════════════════════════════
-- أخطاء «موجود بالفعل» في الخطوة السابقة معناها إن الجداول كانت
-- متعمولة قبل كده. المشكلة إن `create table if not exists` **بيتخطى
-- الجدول الموجود ومابيضفش أي عمود ناقص** — فممكن يكون فيه فرق صامت
-- بين السحابة والسيرفر، ونكتشفه بعد نقل البيانات لما insert يفشل.
--
-- الملف ده بيقارن الاتنين عمود-بعمود ودالة-بدالة.
-- ⚠️ مابيغيّرش أي حاجة — قراءة بس.
-- ⚠️ مش محتاج باسورد: بيستعمل الاتصال 'cloud' اللي اتعمل في الخطوة 1.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1) جداول موجودة في السحابة وناقصة على السيرفر ────────────────
with cloud_t as (
  select * from dblink('cloud', $q$
    select c.relname
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r'
  $q$) as t(relname text)
)
select 'جداول ناقصة على السيرفر' as الفحص,
       coalesce(string_agg(c.relname, ', ' order by c.relname), '✅ ولا واحد') as النتيجة
from cloud_t c
where not exists (select 1 from pg_class lc join pg_namespace ln on ln.oid=lc.relnamespace
                  where ln.nspname='public' and lc.relkind='r' and lc.relname=c.relname);

-- ── 2) أعمدة ناقصة أو نوعها مختلف ───────────────────────────────
with cloud_c as (
  select * from dblink('cloud', $q$
    select c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
    where n.nspname='public' and c.relkind='r'
  $q$) as t(tbl text, col text, typ text)
),
local_c as (
  select c.relname as tbl, a.attname as col, format_type(a.atttypid, a.atttypmod) as typ
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
  where n.nspname='public' and c.relkind='r'
)
select cc.tbl as الجدول, cc.col as العمود,
       cc.typ as نوعه_في_السحابة,
       coalesce(lc.typ, '❌ العمود مش موجود') as على_السيرفر
from cloud_c cc
left join local_c lc on lc.tbl=cc.tbl and lc.col=cc.col
where lc.col is null or lc.typ is distinct from cc.typ
order by cc.tbl, cc.col
limit 60;

-- ── 3) عدّادات المقارنة ─────────────────────────────────────────
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
      (select count(*) from pg_constraint c join pg_namespace n on n.oid=c.connamespace where n.nspname='public')
  $q$) as t(tbls bigint, cols bigint, fns bigint, idx bigint, pol bigint, trg bigint, con bigint)
)
select 'جداول' as البند, c.tbls as السحابة,
       (select count(*) from pg_class x join pg_namespace n on n.oid=x.relnamespace
         where n.nspname='public' and x.relkind='r') as السيرفر from cloud_n c
union all
select 'أعمدة', c.cols, (select count(*) from information_schema.columns where table_schema='public') from cloud_n c
union all
select 'دوال', c.fns, (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public') from cloud_n c
union all
select 'فهارس', c.idx, (select count(*) from pg_indexes where schemaname='public') from cloud_n c
union all
select 'سياسات', c.pol, (select count(*) from pg_policies where schemaname='public') from cloud_n c
union all
select 'تريجرات', c.trg, (select count(*) from pg_trigger t join pg_class x on x.oid=t.tgrelid
  join pg_namespace n on n.oid=x.relnamespace where n.nspname='public' and not t.tgisinternal) from cloud_n c
union all
select 'قيود', c.con, (select count(*) from pg_constraint x join pg_namespace n on n.oid=x.connamespace
  where n.nspname='public') from cloud_n c;

-- ── 4) دوال ناقصة ───────────────────────────────────────────────
with cloud_f as (
  select * from dblink('cloud', $q$
    select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  $q$) as t(sig text)
)
select 'دوال ناقصة على السيرفر' as الفحص,
       coalesce(string_agg(cf.sig, ' · ' order by cf.sig), '✅ ولا واحدة') as النتيجة
from cloud_f cf
where not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' = cf.sig);
