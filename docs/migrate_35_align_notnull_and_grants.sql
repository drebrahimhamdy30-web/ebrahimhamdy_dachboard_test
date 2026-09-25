-- ═══════════════════════════════════════════════════════════════════
--  تسوية آخر الفروق: أعمدة not null + الصلاحيات
-- ═══════════════════════════════════════════════════════════════════
--  بعد migrate_34 نزل الانحراف من ١٣٥ لـ٢٤. الباقي الحقيقي حاجتين:
--
--  ١) ٥ أعمدة not null على السحابة و nullable على السيرفر:
--     dispatch_settings.prep_required · orders.prep_hold ·
--     orders.prep_hold_seconds · wallet.bank_settled · wallet_sms.is_excess
--     (التلاتة الأخيرة اتضافوا nullable في migrate_34 عن قصد، لأن
--      add column not null من غير قيمة على جدول فيه صفوف بتقع.)
--
--  ٢) صلاحيات مختلفة على جداول المخزون. الترحيل نفّذ GRANT السحابة
--     ونجح، وبرضه فضلوا مختلفين — لأن **GRANT بتضيف مابتشيلش**.
--     يعني السيرفر عنده صلاحيات أوسع. والأوسع هنا مش تطابق، ده أمان:
--     مفتاح anon عام في الشاشات، فأي صلاحية زيادة = حاجة يقدر يعملها
--     مش مفروض. التسوية محتاجة REVOKE الأول (زي migrate_30).
--
--  ═══ آمن ═══
--  • تجربة بالافتراضي. للتنفيذ: -v apply=1
--  • الأعمدة: بنملا الفاضي بالقيمة الافتراضية بتاعة السحابة الأول.
--    لو مفيش قيمة افتراضية وفيه صفوف فاضية → بنتخطّى ونقول.
--  • الصلاحيات: بس للجداول الموجودة في الجهتين، وبس للأدوار التلاتة
--    (anon · authenticated · service_role). مابنلمسش postgres ولا
--    supabase_admin — دول ملكية مش صلاحيات.
--  • كل أمر جوّه handler، وآمن يتعاد تشغيله.
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/migrate_35_align_notnull_and_grants.sql
--    # وللتنفيذ:  زوّد  -v apply=1
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on
\if :{?apply}
\else
  \set apply 0
\endif
\pset pager off

-- ── جداول السحابة (عشان منلمسش جداول محلية بحتة) ─────────────────
create temp table _ctabs as
select * from dblink('cloud',
  'select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname=''public'' and c.relkind=''r''') as t(tbl text);

do $$
declare n int;
begin
  select count(*) into n from _ctabs;
  if n < 50 then raise exception 'السحابة رجّعت % جدول بس — مش هعمل حاجة.', n; end if;
  raise notice 'السحابة فيها % جدول.', n;
end $$;

-- ═══ ١) الأعمدة ═══════════════════════════════════════════════════

create temp table _cc as
select * from dblink('cloud', $q$
  select c.relname, a.attname, a.attnotnull, pg_get_expr(ad.adbin, ad.adrelid)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
  where n.nspname = 'public' and c.relkind = 'r'
$q$) as t(tbl text, col text, nn boolean, dflt text);

create temp table _lc as
select c.relname as tbl, a.attname as col, a.attnotnull as nn,
       pg_get_expr(ad.adbin, ad.adrelid) as dflt
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
where n.nspname = 'public' and c.relkind = 'r';

-- الأعمدة اللي السحابة مشدّداها والسيرفر لأ
create temp table _nn(tbl text, col text, dflt text, nulls bigint);
do $$
declare r record; k bigint;
begin
  for r in
    select c.tbl, c.col, c.dflt
    from _cc c
    join _lc l on l.tbl = c.tbl and l.col = c.col
    where c.nn and not l.nn
    order by 1, 2
  loop
    execute format('select count(*) from public.%I where %I is null', r.tbl, r.col) into k;
    insert into _nn values (r.tbl, r.col, r.dflt, k);
  end loop;
end $$;

\echo ''
\echo '════ أعمدة not null على السحابة و nullable على السيرفر ════'
select tbl as "الجدول", col as "العمود",
       coalesce(dflt, '(مفيش قيمة افتراضية)') as "الافتراضي على السحابة",
       nulls as "صفوف فاضية",
       case when nulls = 0 then 'جاهز'
            when dflt is not null then 'هنملاه بالافتراضي الأول'
            else '🔴 فاضي ومفيش افتراضي — هنتخطّاه' end as "الخطة"
from _nn order by 1, 2;

-- ═══ ٢) الصلاحيات ═════════════════════════════════════════════════

create temp table _cg as
select * from dblink('cloud', $q$
  select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type)
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee in ('anon','authenticated','service_role')
  group by 1, 2
$q$) as t(tbl text, grantee text, privs text);

create temp table _lg as
select table_name::text as tbl, grantee::text as grantee,
       string_agg(privilege_type::text, ',' order by privilege_type::text) as privs
from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon','authenticated','service_role')
group by 1, 2;

create temp table _gd as
select coalesce(c.tbl, l.tbl) as tbl,
       coalesce(c.grantee, l.grantee) as grantee,
       c.privs as cloud_privs, l.privs as srv_privs
from _cg c
full join _lg l on l.tbl = c.tbl and l.grantee = c.grantee
where c.privs is distinct from l.privs
  -- بس الجداول الموجودة في الجهتين. جدول محلي بحت (migration_log مثلًا)
  -- السحابة مالهاش رأي في صلاحياته، فمنلمسوش.
  and coalesce(c.tbl, l.tbl) in (select tbl from _ctabs)
  and exists (select 1 from pg_class k join pg_namespace n on n.oid = k.relnamespace
              where n.nspname = 'public' and k.relname = coalesce(c.tbl, l.tbl) and k.relkind = 'r');

\echo ''
\echo '════ فروق الصلاحيات ════'
select tbl as "الجدول", grantee as "الدور",
       coalesce(cloud_privs, '(مفيش)') as "السحابة",
       coalesce(srv_privs, '(مفيش)') as "السيرفر",
       case when srv_privs is null then '🔴 ناقصة'
            when cloud_privs is null then '🟡 زيادة — هتتشال'
            when length(srv_privs) > length(cloud_privs) then '🟡 أوسع — هتتظبط'
            else '⚠️ مختلفة' end as "الحالة"
from _gd order by 1, 2;

-- ═══ التنفيذ ══════════════════════════════════════════════════════
\if :apply

create temp table _log(نوع text, هدف text, ok boolean, تفصيل text);

do $run$
declare r record;
begin
  -- ١) الأعمدة
  for r in select * from _nn order by tbl, col loop
    begin
      if r.nulls > 0 then
        if r.dflt is null then
          insert into _log values ('عمود', r.tbl||'.'||r.col, false,
            r.nulls || ' صف فاضي ومفيش قيمة افتراضية — اتخطّى');
          continue;
        end if;
        execute format('update public.%I set %I = %s where %I is null',
                       r.tbl, r.col, r.dflt, r.col);
      end if;
      execute format('alter table public.%I alter column %I set not null', r.tbl, r.col);
      insert into _log values ('عمود', r.tbl||'.'||r.col, true,
        case when r.nulls > 0 then 'اتملا ' || r.nulls || ' صف ثم اتشدّد' else 'اتشدّد' end);
    exception when others then
      insert into _log values ('عمود', r.tbl||'.'||r.col, false, left(sqlerrm, 150));
    end;
  end loop;

  -- ٢) الصلاحيات — REVOKE الأول، لأن GRANT بتضيف مابتشيلش
  for r in select * from _gd order by tbl, grantee loop
    begin
      execute format('revoke all on public.%I from %I', r.tbl, r.grantee);
      if r.cloud_privs is not null then
        execute format('grant %s on public.%I to %I', r.cloud_privs, r.tbl, r.grantee);
      end if;
      insert into _log values ('صلاحية', r.tbl||' → '||r.grantee, true,
        coalesce(r.cloud_privs, '(اتشالت خالص)'));
    exception when others then
      insert into _log values ('صلاحية', r.tbl||' → '||r.grantee, false, left(sqlerrm, 150));
    end;
  end loop;
end $run$;

\echo ''
\echo '════ النتيجة ════'
select نوع as "النوع", case when ok then '✓ نجح' else '✗ فشل' end as "الحالة",
       count(*) as "العدد"
from _log group by 1, 2 order by 1, 2;

\echo ''
\echo '════ التفصيل ════'
select نوع as "النوع", هدف as "الهدف",
       case when ok then '✓' else '✗' end as "", تفصيل as "التفصيل"
from _log order by ok, نوع, هدف;

\echo ''
\echo '⚠️ شغّل schema_drift_watch.sql — المتوقّع ينزل لحوالي ٨:'
\echo '   ٦ دوال معزولة عمدًا + جدولين نسخ/staging مقصودين.'

\else
\echo ''
\echo '(تجربة — مفيش حاجة اتغيّرت)'
\echo 'للتنفيذ: زوّد  -v apply=1'
\endif
