-- ═══════════════════════════════════════════════════════════════════
--  إيه الفرق بالظبط؟ — الجداول والجرانت الباقيين بعد migrate_34
-- ═══════════════════════════════════════════════════════════════════
--  بعد الاستلحاق نزل الانحراف من ١٣٥ لـ٢٤. الباقي:
--    • ٦ دوال معزولة عمدًا        ← مالهاش تتصلّح غير يوم التحويل
--    • جداول نسخ/staging مؤقتة    ← بنتخطّاها عن قصد
--    • ٥ جداول تعريفها مختلف      ← دول اللي الملف ده بيفحصهم
--      (orders · wallet · wallet_sms · dispatch_settings · stock_flat_shadow)
--    • جرانت لسه مختلف            ← GRANT بتضيف مابتشيلش
--
--  الحارس بيقول «مختلف» بس مابيقولش «فين». الملف ده بيقول فين:
--  عمود بعمود، وصلاحية بصلاحية.
--
--  🔒 قراءة بس — مابيغيّرش أي حاجة.
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/schema_diff_tables_vs_prod.sql
-- ═══════════════════════════════════════════════════════════════════

\pset pager off

-- ── أعمدة السحابة ────────────────────────────────────────────────
create temp table _c_cols as
select * from dblink('cloud', $q$
  select c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
         a.attnotnull, pg_get_expr(ad.adbin, ad.adrelid), a.attnum
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
  where n.nspname = 'public' and c.relkind = 'r'
$q$) as t(tbl text, col text, typ text, nn boolean, dflt text, pos int);

create temp table _l_cols as
select c.relname as tbl, a.attname as col,
       format_type(a.atttypid, a.atttypmod) as typ,
       a.attnotnull as nn, pg_get_expr(ad.adbin, ad.adrelid) as dflt, a.attnum as pos
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
where n.nspname = 'public' and c.relkind = 'r';

\echo ''
\echo '════ فروق الأعمدة (الجداول الموجودة في الجهتين) ════'
\echo '  عمود ناقص · نوع مختلف · not null مختلف · قيمة افتراضية مختلفة'
select coalesce(c.tbl, l.tbl) as "الجدول",
       coalesce(c.col, l.col) as "العمود",
       case when l.col is null then '🔴 ناقص على السيرفر'
            when c.col is null then '🟡 زيادة على السيرفر'
            when c.typ  is distinct from l.typ  then 'النوع مختلف'
            when c.nn   is distinct from l.nn   then 'not null مختلف'
            when c.dflt is distinct from l.dflt then 'القيمة الافتراضية مختلفة'
       end as "الفرق",
       -- ⚠️ مافيش فحص لترتيب الأعمدة: بوستجرس بيسيب فجوة في الترقيم
       --    لما عمود يتشال، والسحابة اتشال منها أعمدة على مدى سنة.
       --    فالأرقام مختلفة ومجموعة الأعمدة متطابقة — ٩٠ سطر ضوضاء.
       case when c.typ is distinct from l.typ then c.typ
            when c.nn is distinct from l.nn then c.nn::text
            when c.dflt is distinct from l.dflt then coalesce(c.dflt,'(مفيش)') end as "السحابة",
       case when c.typ is distinct from l.typ then l.typ
            when c.nn is distinct from l.nn then l.nn::text
            when c.dflt is distinct from l.dflt then coalesce(l.dflt,'(مفيش)') end as "السيرفر"
from _c_cols c
full join _l_cols l on l.tbl = c.tbl and l.col = c.col
where (c.tbl is null or exists (select 1 from _l_cols x where x.tbl = c.tbl))
  and (l.tbl is null or exists (select 1 from _c_cols x where x.tbl = l.tbl))
  and (c.col is null or l.col is null
       or c.typ is distinct from l.typ
       or c.nn is distinct from l.nn
       or c.dflt is distinct from l.dflt)
order by 1, coalesce(c.pos, l.pos);

-- ── الصلاحيات ────────────────────────────────────────────────────
-- GRANT بتضيف مابتشيلش. فلو السيرفر عنده صلاحية زيادة، تنفيذ جرانت
-- السحابة مابيساويهمش — لازم REVOKE الأول (زي migrate_30).
create temp table _c_gr as
select * from dblink('cloud', $q$
  select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type)
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee in ('anon','authenticated','service_role')
  group by 1,2
$q$) as t(tbl text, grantee text, privs text);

create temp table _l_gr as
select table_name::text as tbl, grantee::text as grantee,
       string_agg(privilege_type::text, ',' order by privilege_type::text) as privs
from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon','authenticated','service_role')
group by 1,2;

\echo ''
\echo '════ فروق الصلاحيات ════'
select coalesce(c.tbl, l.tbl) as "الجدول",
       coalesce(c.grantee, l.grantee) as "الدور",
       coalesce(c.privs, '(مفيش)') as "السحابة",
       coalesce(l.privs, '(مفيش)') as "السيرفر",
       case when c.privs is null then '🟡 زيادة على السيرفر'
            when l.privs is null then '🔴 ناقصة على السيرفر'
            else '⚠️ مختلفة' end as "الحالة"
from _c_gr c
full join _l_gr l on l.tbl = c.tbl and l.grantee = c.grantee
where c.privs is distinct from l.privs
order by 1, 2;

\echo ''
\echo 'ملحوظة: 🟡 زيادة = السيرفر أوسع من السحابة. دي مش تجميل —'
\echo '        الزيادة معناها مفتاح anon يقدر يعمل حاجة مش مفروض يعملها.'
