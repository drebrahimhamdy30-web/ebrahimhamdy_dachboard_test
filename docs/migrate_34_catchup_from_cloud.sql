-- ═══════════════════════════════════════════════════════════════════
--  استلحاق الناقص من السحابة — الجداول والأعمدة والدوال والتريجرات
-- ═══════════════════════════════════════════════════════════════════
--  ليه: حارس الانحراف كان بيكذب (شوف schema_drift_watch.sql). بعد ما
--  اتصلّح طلّع ١٣٥ بند. منها ٧ جداول مش موجودة خالص على السيرفر —
--  customers · claims · links · cash_to_wallet · pos_period_closes
--  · branch_stock_seyouf · branch_stock_stage_seyouf — يعني شاشة
--  العملاء والمطالبات وربط الماكينات وإقفال الفترة مكسورين على
--  التست، ومزامنة أرصدة العملاء في n8n كانت هتفشل يوم التحويل.
--
--  ═══ ليه مش مجرد «نفّذ الـDDL» ═══
--  كل نوع بيتصرّف مختلف، والفرق بينهم هو الفرق بين ترحيل بيشتغل
--  وترحيل بيقع في نصّه:
--
--    table      create table if not exists  → آمن، بس **مابيضيفش
--                 عمود لجدول موجود**. عشان كده فيه خطوة أعمدة منفصلة.
--    function   create or replace           → آمن
--    rls/grant  آمن يتعاد
--    index      CREATE INDEX من غير if not exists → بنتخطّى لو موجود
--    constraint alter table add constraint  → بنتخطّى لو الاسم موجود
--    trigger    CREATE TRIGGER              → drop الأول
--    policy     create policy               → drop الأول
--
--  ═══ الأعمدة ═══
--  عمود ناقص بيتضاف nullable حتى لو على السحابة not null — لأن
--  الجدول هنا فيه صفوف، و`add column not null` من غير default بتقع.
--  السكربت بيقول لك أنهي أعمدة محتاجة `set not null` بإيدك بعد ما
--  تتملّى.
--
--  ═══ آمن ═══
--  • تجربة بالافتراضي. للتنفيذ: -v apply=1
--  • كل أمر جوّه handler — أمر بيقع مابيوقّفش الباقي، بيتسجّل ويكمّل
--  • بيتخطّى جداول النسخ والـstaging المؤقتة عن قصد
--  • آمن يتعاد تشغيله
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/migrate_34_catchup_from_cloud.sql
--    # وللتنفيذ الفعلي:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres -v apply=1 < /root/phalix-repo/docs/migrate_34_catchup_from_cloud.sql
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on
\if :{?apply}
\else
  \set apply 0
\endif
\pset pager off

-- ── DDL السحابة كامل (عبر dblink — طازة مش لقطة) ─────────────────
create temp table _cloud_ddl as
select * from dblink('cloud',
  'select ord, kind, obj, ddl from public.v_migration_ddl')
  as t(ord int, kind text, obj text, ddl text);

-- أرضية تعقّل: مانحكمش على مصدر فاضي
do $$
declare n int;
begin
  select count(*) into n from _cloud_ddl;
  if n < 500 then
    raise exception 'مصدر السحابة رجّع % صف بس — مش هعمل حاجة.', n;
  end if;
  raise notice 'جبت % أمر DDL من السحابة.', n;
end $$;

-- ── الناقص = موجود على السحابة ومالوش نظير محلي ──────────────────
create temp table _todo as
with excl as (
  select unnest(array[
    -- معدّلة على السيرفر عن قصد (عزل الإشعارات وتقييم الأداء)
    'notify_fcm_on_assign','notify_on_driver_change','trg_delivery_perf',
    'trg_fail_perf','trg_trip_return_perf','sweep_unrated_perf',
    -- أدوات الترحيل وجداول نسخ قديمة
    'pos_shifts_dupe_backup_20260905','wallet_done_backfill_20260910',
    'v_migration_ddl','v_migration_post'
  ]) as obj
),
norm as (
  select c.ord, c.kind, c.obj, c.ddl,
         regexp_replace(regexp_replace(replace(c.ddl,'public.',''),'\s+',' ','g'),';\s*$','') as d
  from _cloud_ddl c
  where c.obj not in (select e.obj from excl e)
    and split_part(c.obj,':',1) not in (select e.obj from excl e)
    and not exists (select 1 from excl e where c.obj like e.obj || '%')
    -- جداول مؤقتة بتتعمل وتتمسح مع كل دورة مزامنة — مالهاش لازمة
    and c.obj not like '%\_staging'
    and c.obj not like '%\_staging:%'
    and c.obj !~ '_backup_[0-9]{8}'
    and c.obj !~ 'backfill'
),
srv as (
  select kind, regexp_replace(regexp_replace(replace(ddl,'public.',''),'\s+',' ','g'),';\s*$','') as d
  from public.v_migration_ddl
)
select n.ord, n.kind, n.obj, n.ddl
from norm n
where not exists (select 1 from srv s where s.kind = n.kind and s.d = n.d);

-- ── 🔴 حاجز مستقل عن الأسماء: أي DDL فيه رابط ─────────────────────
-- الاستثناءات فوق بتشتغل **بالاسم**. أي دالة جديدة على السحابة فيها
-- رابط ومش في القايمة هتعدّي وتتنفّذ بالحرف — وساعتها تريجر على
-- السيرفر يبقى بينده **السحابة**، ومايبانش: بيشتغل، مابيرميش خطأ،
-- وبيبعت للمكان الغلط.
-- الحاجز ده بيشيلها من التنفيذ ويوديها لقايمة «محتاجة تدخّل يدوي».
create temp table _blocked as
select * from _todo
where ddl like '%__TARGET_URL__%'
   or ddl ~* 'supabase[.]co'
   or ddl ~* 'rxtjoqulmgkkcohmgzgi';

delete from _todo t
using _blocked b
where t.kind = b.kind and t.obj = b.obj;

-- ── أعمدة ناقصة على جداول **موجودة** ─────────────────────────────
-- الجداول دي بتظهر في قايمة الانحراف لأن تعريفها مختلف، بس
-- `create table if not exists` مش هيلمسها. فبنحسب فرق الأعمدة.
create temp table _cloud_cols as
select * from dblink('cloud', $q$
  select c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
         a.attnotnull, pg_get_expr(ad.adbin, ad.adrelid), a.attnum
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
  where n.nspname = 'public' and c.relkind = 'r'
$q$) as t(tbl text, col text, typ text, nn boolean, dflt text, pos int);

create temp table _missing_cols as
select c.tbl, c.col, c.typ, c.nn, c.dflt
from _cloud_cols c
join pg_class k on k.relname = c.tbl
join pg_namespace ns on ns.oid = k.relnamespace and ns.nspname = 'public' and k.relkind = 'r'
where not exists (
  select 1 from pg_attribute a
  where a.attrelid = k.oid and a.attname = c.col and a.attnum > 0 and not a.attisdropped
);

-- ── التقرير ──────────────────────────────────────────────────────
\echo ''
\echo '════ الناقص حسب النوع ════'
select kind as "النوع", count(*) as "العدد" from _todo group by 1 order by 1;
\echo ''
\echo '════ 🔴 اتمنعت — فيها رابط، محتاجة تدخّل يدوي ════'
select kind as "النوع", obj as "الاسم",
       case when ddl like '%__TARGET_URL__%' then 'عنصر نائب __TARGET_URL__'
            else 'رابط السحابة مكتوب صريح' end as "السبب"
from _blocked order by 1, 2;


\echo ''
\echo '════ جداول مش موجودة خالص ════'
select t.obj as "الجدول"
from _todo t
where t.kind = 'table'
  and not exists (select 1 from pg_class k join pg_namespace n on n.oid=k.relnamespace
                  where n.nspname='public' and k.relname = t.obj and k.relkind='r')
order by 1;

\echo ''
\echo '════ أعمدة ناقصة على جداول موجودة ════'
select tbl as "الجدول", col as "العمود", typ as "النوع",
       case when nn then 'هتتضاف nullable — راجعها بعدين' else '' end as "ملحوظة"
from _missing_cols order by 1, 2;

-- ── التنفيذ ──────────────────────────────────────────────────────
\if :apply

create temp table _log(ord int, kind text, obj text, ok boolean, err text);

do $run$
declare
  r record;
  tbl text;
  stmt text;
begin
  -- ١) كل حاجة من قايمة الناقص، بترتيب ord
  for r in select * from _todo order by ord, obj loop
    begin
      if r.kind = 'index' then
        -- CREATE INDEX من غير if not exists — نتخطّى لو الاسم موجود
        if exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                   where n.nspname='public' and c.relname = r.obj) then
          insert into _log values (r.ord, r.kind, r.obj, true, '(موجود — اتخطّى)');
          continue;
        end if;

      elsif r.kind in ('constraint','fk') then
        if exists (select 1 from pg_constraint where conname = split_part(r.obj,':',1)) then
          insert into _log values (r.ord, r.kind, r.obj, true, '(موجود — اتخطّى)');
          continue;
        end if;

      elsif r.kind = 'trigger' then
        -- اسم التريجر مش فريد في القاعدة، فبنشيله من الجدول اللي في الـDDL
        tbl := substring(r.ddl from 'ON public\.([A-Za-z0-9_]+)');
        if tbl is not null then
          execute format('drop trigger if exists %I on public.%I', r.obj, tbl);
        end if;

      elsif r.kind = 'policy' then
        tbl := substring(r.ddl from 'on public\.([A-Za-z0-9_]+)');
        if tbl is not null then
          execute format('drop policy if exists %I on public.%I', r.obj, tbl);
        end if;
      end if;

      execute r.ddl;
      insert into _log values (r.ord, r.kind, r.obj, true, null);
    exception when others then
      insert into _log values (r.ord, r.kind, r.obj, false, left(sqlerrm, 160));
    end;
  end loop;

  -- ٢) الأعمدة الناقصة على جداول موجودة — nullable دايمًا
  for r in select * from _missing_cols order by tbl, col loop
    begin
      stmt := format('alter table public.%I add column if not exists %I %s',
                     r.tbl, r.col, r.typ);
      if r.dflt is not null then stmt := stmt || ' default ' || r.dflt; end if;
      execute stmt;
      insert into _log values (35, 'column', r.tbl || '.' || r.col, true,
        case when r.nn then 'اتضاف nullable — على السحابة not null' else null end);
    exception when others then
      insert into _log values (35, 'column', r.tbl || '.' || r.col, false, left(sqlerrm, 160));
    end;
  end loop;
end $run$;

\echo ''
\echo '════ النتيجة ════'
select case when ok then '✓ نجح' else '✗ فشل' end as "الحالة",
       count(*) as "العدد"
from _log group by 1 order by 1;

\echo ''
\echo '════ اللي فشل — دي المحتاجة عين ════'
select kind as "النوع", obj as "الاسم", err as "الخطأ"
from _log where not ok order by ord, obj;

\echo ''
\echo '════ ملاحظات ════'
select obj as "الاسم", err as "الملحوظة"
from _log where ok and err is not null and err not like '(موجود%' order by obj;

\echo ''
\echo '⚠️ شغّل schema_drift_watch.sql دلوقتي — لازم ينزل من 135 لرقم صغير.'
\echo '   الباقي المتوقّع: الدوال الستة المعزولة بس.'

\else
\echo ''
\echo '(تجربة — مفيش حاجة اتغيّرت)'
\echo 'للتنفيذ: زوّد  -v apply=1  على أمر psql'
\endif
