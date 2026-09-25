-- ═══════════════════════════════════════════════════════════════════
--  مقارنة كاملة: كتالوج السيرفر مقابل كتالوج السحابة
-- ═══════════════════════════════════════════════════════════════════
--  ليه الملف ده موجود:
--
--  حارس الانحراف اليومي (`schema_drift_watch.sql`) بيقول «صفر انحراف»
--  من أسبوع. وفي يوم واحد اتكشف إنه فايته:
--     • ١٣ جدول + ٤٤ دالة ملكيتهم غلط   (migrate_33)
--     • ١٥ دالة ناقصة خالص — منها شاشة العملاء وتقارير الشيفتات
--       وإقفال الفترة                    (schema_diff_funcs_vs_prod)
--
--  الحارس بيقارن **نص أوامر DDL** جاي من فيو على السحابة. الملف ده
--  بيقارن **الكتالوج نفسه**، قاعدة بقاعدة، عبر dblink على السيرفر
--  الأجنبي `cloud`. مصدر قياس مستقل تمامًا.
--
--  🔑 المبدأ: الحارس اللي بيكذب أوحش من إنه مايكونش موجود. فقبل ما
--     نصلّح الحارس لازم نعرف بيفوّت إيه بالظبط — مش نخمّن.
--
--  🔒 مفيش كلمة سر: dblink بياخد اسم السيرفر الأجنبي ويستعمل الـ
--     user mapping الموجود.
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/schema_diff_full_vs_prod.sql
-- ═══════════════════════════════════════════════════════════════════

\pset pager off
\timing off

-- ── بنجيب كتالوج السحابة مرة واحدة في جدول مؤقت ──────────────────
-- استعلام واحد بيرجّع (النوع, الهوية) عشان منعملش ٨ رحلات للسحابة.
create temp table _cloud as
select * from dblink('cloud', $q$
    select 'جدول'::text,    tablename::text from pg_tables  where schemaname='public'
  union all
    select 'عمود',  c.relname || '.' || a.attname || ':' || format_type(a.atttypid, a.atttypmod)
      from pg_attribute a join pg_class c on c.oid=a.attrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind='r' and a.attnum>0 and not a.attisdropped
  union all
    select 'تريجر', c.relname || ':' || t.tgname
      from pg_trigger t join pg_class c on c.oid=t.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and not t.tgisinternal
  union all
    select 'سياسة', c.relname || ':' || p.polname
      from pg_policy p join pg_class c on c.oid=p.polrelid
      join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
  union all
    select 'فهرس', indexname::text from pg_indexes where schemaname='public'
  union all
    select 'قيد', c.relname || ':' || con.conname
      from pg_constraint con join pg_class c on c.oid=con.conrelid
      join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
  union all
    select 'view', viewname::text from pg_views where schemaname='public'
  union all
    select 'سيكوينس', sequencename::text from pg_sequences where schemaname='public'
$q$) as t(نوع text, هوية text);

-- ── ونفس الاستعلام بالظبط محليًا ─────────────────────────────────
create temp table _local as
    select 'جدول'::text as نوع, tablename::text as هوية from pg_tables where schemaname='public'
  union all
    select 'عمود', c.relname || '.' || a.attname || ':' || format_type(a.atttypid, a.atttypmod)
      from pg_attribute a join pg_class c on c.oid=a.attrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind='r' and a.attnum>0 and not a.attisdropped
  union all
    select 'تريجر', c.relname || ':' || t.tgname
      from pg_trigger t join pg_class c on c.oid=t.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and not t.tgisinternal
  union all
    select 'سياسة', c.relname || ':' || p.polname
      from pg_policy p join pg_class c on c.oid=p.polrelid
      join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
  union all
    select 'فهرس', indexname::text from pg_indexes where schemaname='public'
  union all
    select 'قيد', c.relname || ':' || con.conname
      from pg_constraint con join pg_class c on c.oid=con.conrelid
      join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
  union all
    select 'view', viewname::text from pg_views where schemaname='public'
  union all
    select 'سيكوينس', sequencename::text from pg_sequences where schemaname='public';

-- ── ١) الملخص ────────────────────────────────────────────────────
select coalesce(c.نوع, l.نوع) as النوع,
       coalesce(c.n,0) as السحابة, coalesce(l.n,0) as السيرفر,
       coalesce(l.n,0) - coalesce(c.n,0) as الفرق
from (select نوع, count(*) n from _cloud group by 1) c
full join (select نوع, count(*) n from _local group by 1) l using (نوع)
order by 1;

-- ── ٢) ناقص على السيرفر — دي اللي بتكسر حاجة ─────────────────────
select '🔴 ناقص' as الحالة, نوع, هوية
from (select نوع, هوية from _cloud except select نوع, هوية from _local) a
order by نوع, هوية;

-- ── ٣) زيادة على السيرفر ─────────────────────────────────────────
-- متوقّع: الفورمات الطولي (branch_stock_* · stock_flat_shadow)،
-- جداول النسخ الاحتياطي، وفيوهات الهجرة. أي حاجة تانية تستاهل سؤال.
select '🟡 زيادة' as الحالة, نوع, هوية
from (select نوع, هوية from _local except select نوع, هوية from _cloud) b
order by نوع, هوية;

-- ── ٤) الدوال اللي على السيرفر بس — أي واحدة منها منفذ؟ ──────────
-- exec_sql(query text) اتكشفت على السيرفر ومش على السحابة. دالة
-- بتنفّذ SQL عشوائي + SECURITY DEFINER + صلاحية لـanon = تنفيذ SQL
-- كامل من مفتاح عام. الاستعلام ده بيقول مين يقدر ينادي إيه.
select p.proname as الدالة,
       p.prosecdef as "SECURITY DEFINER",
       pg_get_userbyid(p.proowner) as المالك,
       coalesce(string_agg(g.grantee, ', ' order by g.grantee), '(محدش)') as "مين ينادي"
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
left join information_schema.routine_privileges g
       on g.specific_schema = 'public'
      and g.routine_name = p.proname
      and g.privilege_type = 'EXECUTE'
      and g.grantee in ('anon','authenticated','service_role','PUBLIC')
where n.nspname = 'public'
  and p.proname in ('exec_sql','call_edge','edge_url','n8n_url')
group by 1,2,3
order by 1;
