-- ═══════════════════════════════════════════════════════════════════
--  بوابة وجود البيانات: الجدول موجود ≠ الجدول فيه بيانات
-- ═══════════════════════════════════════════════════════════════════
--  🔴 ليه البوابة دي موجودة:
--  2026-10-18، شاشة فواتير الشراء مابتعرضش بيانات. الجدول موجود،
--  الأعمدة موجودة، الصلاحيات صح، الدوال موجودة — **والانحراف صفر**.
--  وبرضه purchase_invoices فيه 0 صف على السيرفر و 20,802 على السحابة.
--
--  السبب كان إن جسر cloudsrc مابيضمّش الجداول الجديدة، فالمزامنة
--  مش شايفة لها نظير وبتسيبها فاضية. والعرض **مش رسالة خطأ** —
--  الشاشة بتفتح وتقول «مفيش بيانات»، فمحدش بيشك.
--
--  الدرس: **حارس الانحراف مايشوفش الفاضي.** الجدول الفاضي مطابق
--  تمامًا في السكيما. فبوابة «الانحراف = صفر» مش كافية لوحدها قبل
--  التحويل — محتاجة البوابة دي معاها.
--
--  ═══ إزاي بتقيس ═══
--  مرحلة ١: مقارنة سريعة بتقديرات الكتالوج (n_live_tup) للمرشّحين.
--  مرحلة ٢: count(*) **فعلي** على المرشّحين بس — عشان التقدير بيقدم
--           بعد تحميل جديد وكان هيطلّع إنذارات كاذبة.
--  يعني مابنعتمدش على التقدير في الحكم، بس في تضييق البحث.
--
--  🔒 قراءة بس.
--  بيطبع OK أو قايمة الجداول اللي السحابة فيها بيانات والسيرفر لأ.
-- ═══════════════════════════════════════════════════════════════════

\pset pager off
\set ON_ERROR_STOP on

-- ── تقديرات السحابة ───────────────────────────────────────────────
create temp table _cn as
select * from dblink('cloud', $q$
  select c.relname, coalesce(s.n_live_tup, 0)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_stat_user_tables s on s.relid = c.oid
  where n.nspname = 'public' and c.relkind in ('r','p')
$q$) as t(tbl text, est bigint);

create temp table _ln as
select c.relname as tbl, coalesce(s.n_live_tup, 0) as est
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where n.nspname = 'public' and c.relkind in ('r','p');

do $sane$
declare n int;
begin
  select count(*) into n from _cn;
  if n < 50 then
    raise exception 'السحابة رجّعت % جدول بس — الرابط مقطوع. مش هحكم.', n;
  end if;
end $sane$;

-- ── المرشّحون: السحابة فيها والسيرفر شكله فاضي أو أقل بكتير ───────
-- بنستثني المؤقت والنسخ وأدوات الترحيل — دي مقصود إنها مش متزامنة.
create temp table _cand as
select c.tbl, c.est as cloud_est, coalesce(l.est, -1) as srv_est
from _cn c
left join _ln l on l.tbl = c.tbl
where c.est > 0
  and c.tbl not like '%\_staging'
  and c.tbl not like '%\_staging\_%'
  and c.tbl !~ '_backup_[0-9]{8}'
  and c.tbl !~ 'backfill'
  and c.tbl not in ('v_migration_ddl','v_migration_post','migration_log',
                    'migration_data_log','cloud_sync_log')
  and (l.est is null or l.est = 0 or l.est < c.est * 0.5);

-- ── الحكم: count(*) فعلي على المرشّحين بس ────────────────────────
create temp table _verdict(tbl text, cloud_n bigint, srv_n bigint, حالة text);

do $chk$
declare r record; sn bigint; cn bigint;
begin
  for r in select * from _cand order by cloud_est desc loop
    -- الجدول مش موجود محليًا؟ ده انحراف سكيما مش بيانات — الحارس شغله
    if r.srv_est = -1 then
      insert into _verdict values (r.tbl, r.cloud_est, -1, '🔴 الجدول مش موجود على السيرفر');
      continue;
    end if;
    begin
      execute format('select count(*) from public.%I', r.tbl) into sn;
    exception when others then
      insert into _verdict values (r.tbl, r.cloud_est, -2, '⚠️ مقدرتش أعدّ: ' || left(sqlerrm, 60));
      continue;
    end;
    -- العدد الحقيقي من السحابة للمرشّح ده بس
    select n into cn from dblink('cloud',
      format('select count(*) from public.%I', r.tbl)) as t(n bigint);
    if cn = 0 then
      continue;                                   -- السحابة فاضية كمان — عادي
    elsif sn = 0 then
      insert into _verdict values (r.tbl, cn, sn, '🔴 فاضي على السيرفر والسحابة فيها بيانات');
    elsif sn < cn * 0.5 then
      insert into _verdict values (r.tbl, cn, sn, '⚠️ أقل من نص السحابة');
    end if;
  end loop;
end $chk$;

\echo ''
\echo '════ بوابة وجود البيانات ════'
select tbl as "الجدول", cloud_n as "السحابة", srv_n as "السيرفر", حالة as "الحكم"
from _verdict order by cloud_n desc;

\echo ''
select case when count(*) = 0
            then 'OK — كل جدول فيه بيانات على السحابة فيه بيانات على السيرفر'
            else 'MISMATCH — ' || count(*)::text || ' جدول محتاج مزامنة. شغّل sync-from-cloud.sh --full'
       end as "الخلاصة"
from _verdict;
