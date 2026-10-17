-- ═══════════════════════════════════════════════════════════════════
--  مسح شامل قبل التحويل: السيرفر مقابل السحابة — **بالمحتوى**
-- ═══════════════════════════════════════════════════════════════════
--  ليه ملف جديد والأدوات موجودة:
--  عندنا حارس انحراف وتلات ملفات مقارنة، بس كل واحد بيقيس زاوية
--  والمقارنة متفرّقة. وقبل التحويل محتاجين **تقرير واحد** يجاوب
--  سؤال واحد: السيرفر يساوي السحابة ولا لأ، وفين بالظبط الفرق.
--
--  ═══ المقارنة بالمحتوى مش بالاسم ═══
--  كل كائن بياخد **بصمة من محتواه**:
--    دالة   → جسمها كامل (pg_get_functiondef)
--    عمود   → النوع + not null + القيمة الافتراضية
--    تريجر  → تعريفه كامل، ومعاه اسم جدوله (الاسم مش فريد)
--    سياسة  → الشرط والأدوار والأمر
--    فهرس   → نص التعريف
--    قيد    → pg_get_constraintdef، ومعاه جدوله
--    صلاحية → قايمة الصلاحيات مرتبة (جداول ودوال)
--    ملكية  → اسم المالك (دالة SECURITY DEFINER بتشتغل بصلاحياته)
--  يعني «نفس الاسم» مش كفاية — دالة اسمها واحد وجسمها مختلف بتظهر.
--
--  ═══ 🔑 أهم تفصيلة في التصميم ═══
--  نص استعلام البصمات **مكتوب مرة واحدة** في جدول مؤقت، وبيتنفّذ على
--  الجهتين: على السحابة بـdblink، ومحليًا بتنفيذ ديناميكي لنفس النص.
--  أي مقارنة بنسختين من الاستعلام بتنحرف مع أول تعديل وتكذب — وإحنا
--  عندنا حارس قعد أسبوع بيكذب بسبب سطر واحد.
--
--  ═══ مافيش استثناء مخفي ═══
--  الكائنات المستثناة بقصد (دوال العزل · جداول النسخ · staging ·
--  أدوات الترحيل) **بتتعرض في قسم خاص** مش بتتشال بصمت. القارئ
--  يشوفها ويحكم بنفسه.
--
--  🔒 قراءة بس. مابيعدّلش أي حاجة في أي قاعدة.
--
--  التشغيل (على السيرفر):
--    scripts/pre-cutover-audit.sh          # بيحفظ تقرير في /root
--  أو مباشرة:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < docs/pre_cutover_audit.sql
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on
\pset pager off
\timing off

-- ── توحيد الصياغة: مرة واحدة، وبتتطبّق على الجهتين ────────────────
-- بوستجرس بيكتب نفس الحاجة بشكلين حسب search_path (REFERENCES stores
-- مقابل REFERENCES public.stores)، والمسافات بتختلف. من غير التوحيد
-- ده بياخد 46 مفتاح أجنبي و48 تريجر يبانوا مختلفين وهم حرف بحرف واحد.
create or replace function pg_temp.nrm(t text) returns text
language sql immutable as $fn$
  select regexp_replace(
           regexp_replace(
             replace(coalesce($1, ''), 'public.', ''),
           '\s+', ' ', 'g'),
         ';\s*$', '')
$fn$;

-- ═══════════════════════════════════════════════════════════════════
--  استعلام البصمات — نسخة واحدة، تتنفّذ على الجهتين
-- ═══════════════════════════════════════════════════════════════════
create temp table _sql(q text);
insert into _sql values ($SIG$
  -- جدول: وجوده فقط (الفرق في الأعمدة بيظهر في سطور «عمود»)
  select 'جدول'::text as kind, 'table:' || c.relname as key, '1'::text as raw
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','p')

  union all
  -- عمود: النوع + not null + القيمة الافتراضية
  select 'عمود', 'column:' || c.relname || '.' || a.attname,
         format_type(a.atttypid, a.atttypmod) || ' | notnull=' || a.attnotnull
         || ' | default=' || coalesce(pg_get_expr(ad.adbin, ad.adrelid), '-')
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
  where n.nspname = 'public' and c.relkind in ('r','p')

  union all
  -- دالة: الجسم كامل. بنستبعد دوال الإضافات (ملكيتها بتاعة الإضافة)
  select 'دالة', 'function:' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind in ('f','p')
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')

  union all
  -- SECURITY DEFINER منفصلة: دالة بتشتغل بصلاحيات مالكها، فتغيّرها
  -- تغيير في الأمان مش في المنطق
  select 'دالة-امتياز', 'secdef:' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         case when p.prosecdef then 'SECURITY DEFINER' else 'invoker' end
         || ' | owner=' || pg_get_userbyid(p.proowner)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind in ('f','p')
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')

  union all
  select 'view', 'view:' || c.relname, pg_get_viewdef(c.oid, true)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('v','m')

  union all
  -- تريجر: مع اسم جدوله — اسم التريجر **مش فريد** في القاعدة
  -- (trg_closed_period موجود على ٤ جداول)
  select 'تريجر', 'trigger:' || cl.relname || ':' || t.tgname, pg_get_triggerdef(t.oid)
  from pg_trigger t join pg_class cl on cl.oid = t.tgrelid
  join pg_namespace n on n.oid = cl.relnamespace
  where n.nspname = 'public' and not t.tgisinternal

  union all
  select 'سياسة', 'policy:' || p.tablename || ':' || p.policyname,
         p.permissive || ' | ' || p.cmd || ' | ' || array_to_string(p.roles, ',')
         || ' | using=' || coalesce(p.qual, '-')
         || ' | check=' || coalesce(p.with_check, '-')
  from pg_policies p where p.schemaname = 'public'

  union all
  select 'RLS', 'rls:' || c.relname, case when c.relrowsecurity then 'on' else 'off' end
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','p')

  union all
  select 'فهرس', 'index:' || i.indexname, i.indexdef
  from pg_indexes i where i.schemaname = 'public'

  union all
  -- قيد: مع جدوله — one_row موجود على جدولين
  select 'قيد', 'constraint:' || cl.relname || ':' || con.conname, pg_get_constraintdef(con.oid)
  from pg_constraint con join pg_class cl on cl.oid = con.conrelid
  join pg_namespace n on n.oid = cl.relnamespace
  where n.nspname = 'public'

  union all
  -- سيكوينس: النوع والخطوة بس — last_value بيختلف بشكل شرعي
  select 'سيكوينس', 'sequence:' || s.sequencename,
         s.data_type::text || ' | inc=' || s.increment_by
  from pg_sequences s where s.schemaname = 'public'

  union all
  -- صلاحيات الجداول: anon مفتاح عام، فأي زيادة = باب مفتوح
  select 'صلاحية-جدول',
         'grant:' || c.relname || ':' ||
           case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,
         string_agg(a.privilege_type, ',' order by a.privilege_type)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(c.relacl) a
  where n.nspname = 'public' and c.relkind in ('r','p','v','m')
    and (a.grantee = 0
         or pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role'))
  group by c.relname, a.grantee

  union all
  -- صلاحيات تنفيذ الدوال: PUBLIC بياخد EXECUTE افتراضيًا، فأي دالة
  -- جديدة بتفتح الباب تاني لو محدش سحبها
  select 'صلاحية-دالة', 'fngrant:' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         coalesce((select string_agg(t.x, ',' order by t.x) from (
           select distinct case when a.grantee = 0 then 'PUBLIC'
                                else pg_get_userbyid(a.grantee) end as x
           from aclexplode(p.proacl) a
           where a.privilege_type = 'EXECUTE'
             and (a.grantee = 0
                  or pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role'))
         ) t), 'افتراضي — PUBLIC عندها EXECUTE ضمنيًا')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind in ('f','p')
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')

  union all
  -- ملكية الجداول: rename محتاج ملكية مش إذن كتابة (مزامنة المخزون)
  select 'ملكية', 'owner:table:' || c.relname, pg_get_userbyid(c.relowner)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','p','v','m')

  union all
  select 'إضافة', 'extension:' || e.extname, e.extversion
  from pg_extension e
$SIG$);

-- ── السحابة (dblink — طازة، مش من لقطة cloudsrc) ─────────────────
create temp table _cloud as
select * from dblink('cloud', (select q from _sql)) as t(kind text, key text, raw text);

-- ── السيرفر (نفس النص بالحرف) ─────────────────────────────────────
do $exec$
begin
  execute 'create temp table _local as ' || (select q from _sql);
end $exec$;

-- ── أرضية تعقّل: الفاضي مش نضيف ──────────────────────────────────
do $sane$
declare nc int; nl int;
begin
  select count(*) into nc from _cloud;
  select count(*) into nl from _local;
  if nc < 1000 then
    raise exception 'السحابة رجّعت % بصمة بس — الرابط مقطوع. مش هعمل تقرير على بيانات ناقصة.', nc;
  end if;
  if nl < 1000 then
    raise exception 'السيرفر رجّع % بصمة بس — حاجة غلط. مش هحكم.', nl;
  end if;
  raise notice 'المقارنة: % بصمة من السحابة مقابل % من السيرفر.', nc, nl;
end $sane$;

-- ── المستثنى بقصد — معروض مش مخفي ────────────────────────────────
create temp table _excl(pat text, why text);
insert into _excl values
  ('%notify_fcm_on_assign%',        'عزل الإشعارات — يتفك يوم التحويل'),
  ('%notify_on_driver_change%',     'عزل الإشعارات — يتفك يوم التحويل'),
  ('%trg_delivery_perf%',           'عزل تقييم الأداء (Google Maps = فلوس)'),
  ('%trg_fail_perf%',               'عزل تقييم الأداء'),
  ('%trg_trip_return_perf%',        'عزل تقييم الأداء'),
  ('%sweep_unrated_perf%',          'عزل تقييم الأداء'),
  ('%\_staging%',                   'جدول مؤقت بيتعمل ويتمسح مع دورة المزامنة'),
  ('%\_backup\_2%',                 'جدول نسخة من إصلاح قديم'),
  ('%backfill%',                    'جدول نسخة من إصلاح قديم'),
  ('%v_migration_ddl%',             'أداة ترحيل'),
  ('%v_migration_post%',            'أداة ترحيل'),
  ('%migration_log%',               'أداة ترحيل (محلي بحت)'),
  ('%migration_data_log%',          'أداة ترحيل (محلي بحت)'),
  ('%cloud_sync_log%',              'سجل المزامنة (محلي بحت)');

create temp view _ex as
select d.* from (
  select coalesce(c.kind, l.kind) as kind,
         coalesce(c.key, l.key)   as key,
         c.raw as cloud_raw, l.raw as srv_raw
  from _cloud c full join _local l using (key)
) d
where exists (select 1 from _excl e where d.key like e.pat);

-- ═══════════════════════════════════════════════════════════════════
--  المقارنة
-- ═══════════════════════════════════════════════════════════════════
create temp view _diff as
select coalesce(c.kind, l.kind) as kind,
       coalesce(c.key, l.key)   as key,
       case when l.key is null then 'ناقص على السيرفر'
            when c.key is null then 'زيادة على السيرفر'
            else 'المحتوى مختلف' end as حالة,
       c.raw as cloud_raw, l.raw as srv_raw
from _cloud c
full join _local l using (key)
where (l.key is null or c.key is null
       or pg_temp.nrm(c.raw) is distinct from pg_temp.nrm(l.raw))
  and not exists (select 1 from _excl e where coalesce(c.key, l.key) like e.pat);

\echo ''
\echo '╔══════════════════════════════════════════════════════════════╗'
\echo '║   تقرير ما قبل التحويل — السيرفر مقابل السحابة بالمحتوى      ║'
\echo '╚══════════════════════════════════════════════════════════════╝'

\echo ''
\echo '── ١) الملخص: كل نوع، كام في الجهتين وكام فرق ──'
select coalesce(c.kind, l.kind, d.kind) as "النوع",
       coalesce(c.n, 0) as "السحابة",
       coalesce(l.n, 0) as "السيرفر",
       coalesce(d.ناقص, 0)  as "ناقص",
       coalesce(d.زيادة, 0) as "زيادة",
       coalesce(d.مختلف, 0) as "محتواه مختلف"
from (select kind, count(*) n from _cloud group by 1) c
full join (select kind, count(*) n from _local group by 1) l using (kind)
full join (
  select kind,
         count(*) filter (where حالة = 'ناقص على السيرفر')  as ناقص,
         count(*) filter (where حالة = 'زيادة على السيرفر') as زيادة,
         count(*) filter (where حالة = 'المحتوى مختلف')     as مختلف
  from _diff group by 1
) d using (kind)
order by 1;

\echo ''
\echo '── ٢) 🔴 ناقص على السيرفر — ده اللي يكسر شاشة أو ورك فلو ──'
select kind as "النوع", key as "الكائن" from _diff
where حالة = 'ناقص على السيرفر' order by kind, key;

\echo ''
\echo '── ٣) ⚠️ موجود في الجهتين والمحتوى مختلف — أخطر نوع ──'
\echo '    (بيشتغل، مابيرميش خطأ، وبيعمل حاجة تانية)'
select kind as "النوع", key as "الكائن",
       left(pg_temp.nrm(cloud_raw), 90) as "السحابة",
       left(pg_temp.nrm(srv_raw), 90)   as "السيرفر"
from _diff where حالة = 'المحتوى مختلف' order by kind, key;

\echo ''
\echo '── ٤) 🟡 زيادة على السيرفر ──'
\echo '    (متوقّع: الفورمات الطولي وجداول أدوات محلية. أي حاجة تانية تستاهل سؤال)'
select kind as "النوع", key as "الكائن" from _diff
where حالة = 'زيادة على السيرفر' order by kind, key;

\echo ''
\echo '── ٤ب) 🔴 قيود فريدة زيادة على السيرفر — دي بتوقّف المزامنة ──'
\echo '    (الحارس اتجاه واحد: بيسأل إيه الناقص، عمره ما يسأل إيه الزيادة.'
\echo '     وقيد فريد زيادة مش اختلاف تجميلي — بيرفض صفوف السحابة الشرعية.)'
-- حصلت فعلًا 2026-10-14→17: السحابة وسّعت crm_return_bill_day_uq ليشمل
-- return_day، والسيرفر فضل عنده القديم crm_return_bill_uq من غير اليوم.
-- فصفّين في السحابة يختلفوا في اليوم بس = مسموحين هناك ومتعارضين هنا،
-- ومزامنة contract_return_matches وقفت ٣ أيام. وإحنا كنا بنقرا الانحراف
-- وهو بيقول «عمود ناقص» — وده كان العرض مش المرض.
select kind as "النوع", key as "الكائن",
       left(pg_temp.nrm(srv_raw), 110) as "التعريف على السيرفر"
from _diff
where حالة = 'زيادة على السيرفر'
  and kind in ('فهرس','قيد')
  and (srv_raw ilike '%unique%' or srv_raw ilike '%primary key%')
order by kind, key;

\echo ''
\echo '── ٥) مستثنى بقصد — معروض عشان ما يبقاش مخفي ──'
select e.why as "السبب", count(*) as "عدد الكائنات",
       string_agg(distinct split_part(x.key, ':', 2), ', ' order by split_part(x.key, ':', 2)) as "أمثلة"
from _ex x join _excl e on x.key like e.pat
group by e.why order by 2 desc;
\echo ''
\echo '── ٦) العزل: لازم يفضل مفعّل لحد لحظة التحويل ──'
\echo '    (أي كرون على السيرفر والسحابة شغّالة = إشعار مرتين للطيار)'
-- كل بند جوّه handler لوحده: لو جدول مش موجود يقول «مقدرتش أفحص»
-- بدل ما التقرير كله يقع. تقرير بيقع أوحش من تقرير ناقص.
create temp table _iso(بند text, قيمة text, حكم text);
do $iso$
declare k bigint;
begin
  begin
    select count(*) into k from cron.job;
    insert into _iso values ('كرونات على السيرفر', k::text,
      case when k = 0 then '✓ معزول' else '🔴 لازم صفر قبل التحويل' end);
  exception when others then
    insert into _iso values ('كرونات على السيرفر', 'مقدرتش أفحص', '⚠️ ' || left(sqlerrm, 60));
  end;

  begin
    select count(*) into k
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and not t.tgisinternal
      and t.tgenabled <> 'D' and t.tgname ~* 'notify|perf';
    insert into _iso values ('تريجرات إشعارات/أداء مفعّلة', k::text,
      case when k = 0 then '✓ معزولة' else '🔴 مفكوكة بدري' end);
  exception when others then
    insert into _iso values ('تريجرات إشعارات/أداء مفعّلة', 'مقدرتش أفحص', '⚠️');
  end;

  begin
    -- كرونات السحابة: cutover.sh go بيجدولهم كلهم من فيو **حي**، فالعدد
    -- بيتغيّر. الدليل كان مكتوب فيه ١٢ وبقوا ١٦ — رقم محفور بيقدم.
    -- كرون ناقص بعد التحويل مابيرميش خطأ، بيخلّي أرقام واقفة.
    select count(*) into k from dblink('cloud',
      'select 1 from cron.job where active') as t(x int);
    insert into _iso values ('كرونات السحابة النشطة', k::text,
      'cutover.sh go بيجدولهم كلهم — بالاسم فبيستبدل مش بيضيف');
  exception when others then
    insert into _iso values ('كرونات السحابة النشطة', 'مقدرتش أفحص', '⚠️');
  end;

  begin
    execute 'select count(*) from public.driver_fcm_tokens' into k;
    insert into _iso values ('توكنات تليفونات الطيارين', k::text,
      case when k = 0 then '✓ فاضي' else '⚠️ فيه توكنات حقيقية — حزام أمان ناقص' end);
  exception when others then
    insert into _iso values ('توكنات تليفونات الطيارين', 'الجدول مش موجود', '✓');
  end;
end $iso$;
select * from _iso;

\echo ''
\echo '── ٧) جداول التحكّم: عدد الصفوف في الجهتين ──'
\echo '    (دي اللي لو اختلفت تختفي شاشات أو صلاحيات بعد التحويل)'
create temp table _ctl(tbl text, n bigint);
do $ctlget$
begin
  begin
    insert into _ctl
    select * from dblink('cloud', $CTL$
      select 'app_pages', count(*) from app_pages
      union all select 'page_permissions', count(*) from page_permissions
      union all select 'tab_permissions',  count(*) from tab_permissions
      union all select 'app_page_tabs',    count(*) from app_page_tabs
      union all select 'branches',         count(*) from branches
      union all select 'regions',          count(*) from regions
      union all select 'dispatch_settings',count(*) from dispatch_settings
      union all select 'branch_users',     count(*) from branch_users
      union all select 'drivers',          count(*) from drivers
    $CTL$) as t(tbl text, n bigint);
  exception when others then
    raise notice 'جداول التحكّم: مقدرتش أجيبها من السحابة — %', left(sqlerrm, 120);
  end;
end $ctlget$;

create temp table _ctl2(tbl text, cloud_n bigint, srv_n bigint);
do $ctl$
declare r record; k bigint;
begin
  for r in select * from _ctl loop
    begin
      execute format('select count(*) from public.%I', r.tbl) into k;
    exception when others then k := -1;
    end;
    insert into _ctl2 values (r.tbl, r.n, k);
  end loop;
end $ctl$;

select tbl as "الجدول", cloud_n as "السحابة", srv_n as "السيرفر",
       case when srv_n < 0 then '🔴 الجدول مش موجود'
            when srv_n = cloud_n then '✓'
            else '⚠️ فرق ' || (cloud_n - srv_n)::text end as "الحكم"
from _ctl2 order by 1;

\echo ''
\echo '── ٨) الحكم ──'
select case when count(*) = 0
            then '✓ السيرفر يساوي السحابة بالمحتوى — جاهز للتحويل'
            else '⚠️ ' || count(*)::text || ' فرق — شوف الأقسام ٢ و٣ و٤'
       end as "الخلاصة",
       count(*) filter (where حالة = 'ناقص على السيرفر')  as "ناقص",
       count(*) filter (where حالة = 'المحتوى مختلف')     as "محتواه مختلف",
       count(*) filter (where حالة = 'زيادة على السيرفر') as "زيادة"
from _diff;

\echo ''
\echo 'الإصلاح: scripts/catchup.sh --apply   ثم شغّل المسح ده تاني.'
\echo 'واللي الاستلحاق مابيعملوش (رابط سحابة صريح · قيد تعريفه مختلف)'
\echo 'بيظهر في خرجه كـ«محتاج قرار بشري» — مش بيعدّي بصمت.'
\echo ''
