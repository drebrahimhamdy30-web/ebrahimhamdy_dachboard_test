-- ═══════════════════════════════════════════════════════════════════
--  مزامنة بيانات السيرفر الذاتي من السحابة (السيرفر = مرآة)
-- ═══════════════════════════════════════════════════════════════════
--  السحابة هي مصدر الحقيقة. السيرفر بيتحدّث منها عبر cloudsrc
--  (postgres_fdw) عشان يفضل جاهز للتحويل في أي لحظة، وعشان التجربة
--  تكون على بيانات حقيقية مش بيانات شهر فات.
--
--  ═══ نمطين ═══
--    delta (الافتراضي) — بيجيب الصفوف اللي اتغيّرت في آخر N يوم.
--                        دقايق. ده اللي بيشتغل كل يوم.
--    full             — بيفضّي الجدول ويجيبه كامل من السحابة.
--                        بطيء. للمرة الأولى وللجداول اللي وراها كتير.
--
--  ═══ التشغيل ═══
--    -- المرة الأولى (كامل، ممكن ياخد نص ساعة أو أكتر):
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres -v mode=full -f - < docs/refresh_data_from_cloud.sql
--
--    -- اليومي:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < docs/refresh_data_from_cloud.sql
--
--  ═══ إزاي بيعرف إيه اللي اتغيّر ═══
--  بيدوّر على عمود وقت في الجدول (updated_at ثم created_at ثم غيرهم
--  بالترتيب في TS_PREF) ويجيب الصفوف اللي وقتها >= التاريخ المطلوب،
--  بيمسح نظيرها المحلي بالمفتاح الأساسي ويحطها مكانها — فالصف اللي
--  **اتعدّل** بييجي مُحدَّث، مش بس الصفوف الجديدة. ده الفرق اللي
--  بيخلّي حالة الطلب على السيرفر تطابق السحابة.
--
--  ⚠️ الحذف مابينتقلش: صف اتمسح من السحابة بيفضل على السيرفر.
--     النمط full بيصلّح ده. عشان كده بنعمل full مرة كل فترة.
--
--  ═══ المستثنى — اقرا ده قبل ما تعدّل القايمة ═══
--    driver_fcm_tokens · driver_push_subscriptions
--        🔴 توكنات تليفونات الطيارين الحقيقيين. اتفضّت عمدًا وقت
--        العزل. لو رجعت، أول تجربة على السيرفر تبعت إشعار لطيار
--        شغّال دلوقتي. متلمسهاش غير يوم التحويل.
--    purchase_orders_flat · code_match_suggestions · consumption_flat
--    stock_flat · stock_flat_meta · jard_category_flags
--        جداول محسوبة محليًا — النقل بيمسح شغل السيرفر ويحط فاضي.
--    stock_san_staging · *_backup_* · *_backfill_*
--        بقايا ترحيل ونسخ مؤقتة.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on
\if :{?mode}
\else
\set mode delta
\endif
\if :{?days}
\else
\set days 3
\endif

set app.sync_mode = :'mode';
set app.sync_days = :'days';

create table if not exists public.cloud_sync_log (
  id          bigserial primary key,
  ran_at      timestamptz not null default now(),
  mode        text,
  tbl         text,
  rows_before bigint,
  rows_after  bigint,
  seconds     numeric,
  status      text,
  detail      text
);

do $sync$
declare
  -- ترتيب تفضيل عمود الوقت: الأول اللي بيتحدّث مع أي تعديل
  TS_PREF constant text[] := array[
    'updated_at','updatedAt','modified_at','audited_at','matched_at',
    'created_at','createdAt','requested_at','fetched_at','tx_at','ran_at'
  ];
  EXCLUDED constant text[] := array[
    'driver_fcm_tokens','driver_push_subscriptions',
    'purchase_orders_flat','code_match_suggestions','consumption_flat',
    'stock_flat','stock_flat_meta','jard_category_flags',
    'stock_san_staging','cloud_sync_log'
  ];
  v_mode  text := current_setting('app.sync_mode', true);
  v_days  int  := coalesce(current_setting('app.sync_days', true), '3')::int;
  v_since timestamptz := now() - make_interval(days => v_days);
  r        record;
  v_cols   text;
  v_pk     text;
  v_ts     text;
  v_ident  boolean;
  v_over   text;
  v_before bigint;
  v_after  bigint;
  v_t0     timestamptz;
  v_done   int := 0;
  v_skip   int := 0;
  v_fail   int := 0;
begin
  -- بيوقف التريجرات وفحص المفاتيح الأجنبية أثناء التحميل.
  -- من غيره ترتيب الجداول بيوقع الإدخال، والتريجرات بتعيد حساب
  -- حاجات المفروض تيجي من السحابة زي ما هي.
  begin
    set local session_replication_role = replica;
  exception when others then
    raise notice '⚠️ مش قادر أوقف التريجرات (محتاج superuser) — ممكن تفشل جداول بسبب ترتيب المفاتيح';
  end;

  raise notice '═══ النمط: %  ·  من تاريخ: %  ═══',
    v_mode, case when v_mode = 'full' then 'الكل' else v_since::date::text end;

  -- ═══ جداول موجودة على السحابة ومش موجودة محليًا ═══
  -- الحلقة تحت بتلفّ على جداول public المحلية، فجدول جديد على السحابة
  -- **عمره ما يدخلها** — ولا بيتسجّل كـskip. كان بيتوه بالساكت تمامًا:
  -- stock_seyouf فضل ناقص على السيرفر وإحنا فاكرين إن المزامنة شغّالة
  -- (اتكشف 2026-09-25). المزامنة مش بتخلق جداول — وده مقصود، بنية
  -- الجدول شغل ترحيل مش شغل نقل بيانات — بس لازم **تعلن** الناقص.
  for r in
    select c2.relname::text as t
      from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace
     where n2.nspname = 'cloudsrc' and c2.relkind in ('f','r','v')
       and not (c2.relname = any (EXCLUDED))
       and c2.relname !~ '_backup_|_backfill_|_staging$'
       and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                        where n.nspname = 'public' and c.relname = c2.relname)
     order by c2.relname
  loop
    insert into public.cloud_sync_log(mode, tbl, status, detail)
      values (v_mode, r.t, 'missing', 'موجود على السحابة ومش موجود محليًا — محتاج ترحيل يعمل الجدول');
    raise warning '⚠️ جدول ناقص محليًا: %  — المزامنة بتتخطّاه. محتاج ترحيل.', r.t;
  end loop;

  for r in
    select c.relname::text as t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and not (c.relname = any (EXCLUDED))
      and c.relname !~ '_backup_|_backfill_|_staging$'
      and exists (select 1 from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace
                  where n2.nspname = 'cloudsrc' and c2.relname = c.relname)
    order by c.relname
  loop
    v_t0 := clock_timestamp();

    -- الأعمدة المشتركة بين الجهتين، والمولّدة مستثناة (مابتتكتبش)
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum)
      into v_cols
    from pg_attribute a
    where a.attrelid = ('public.' || quote_ident(r.t))::regclass
      and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
      and exists (select 1 from pg_attribute a2
                  where a2.attrelid = ('cloudsrc.' || quote_ident(r.t))::regclass
                    and a2.attname = a.attname and a2.attnum > 0 and not a2.attisdropped);

    if v_cols is null then
      insert into public.cloud_sync_log(mode,tbl,status,detail)
        values (v_mode, r.t, 'skip', 'مفيش أعمدة مشتركة');
      v_skip := v_skip + 1; continue;
    end if;

    -- أعمدة identity محتاجة overriding عشان نكتب القيمة الجاية من السحابة
    select exists (select 1 from pg_attribute a
                   where a.attrelid = ('public.' || quote_ident(r.t))::regclass
                     and a.attnum > 0 and not a.attisdropped and a.attidentity in ('a','d'))
      into v_ident;
    v_over := case when v_ident then ' overriding system value ' else ' ' end;

    -- مفتاح أساسي من عمود واحد — لازم للنمط delta
    select a.attname into v_pk
    from pg_constraint con
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
    where con.conrelid = ('public.' || quote_ident(r.t))::regclass
      and con.contype = 'p' and array_length(con.conkey,1) = 1;

    -- عمود الوقت بالترتيب المفضّل
    v_ts := null;
    select p into v_ts from unnest(TS_PREF) with ordinality as u(p, ord)
    where exists (select 1 from pg_attribute a
                  where a.attrelid = ('public.' || quote_ident(r.t))::regclass
                    and a.attname = u.p and a.attnum > 0 and not a.attisdropped)
    order by u.ord limit 1;

    execute format('select count(*) from public.%I', r.t) into v_before;

    begin
      if v_mode = 'full' or v_pk is null or v_ts is null then
        -- كامل: نفضّي ونجيب. (delete مش truncate عشان الـFK)
        execute format('delete from public.%I', r.t);
        execute format('insert into public.%I (%s)%sselect %s from cloudsrc.%I',
                       r.t, v_cols, v_over, v_cols, r.t);
      else
        -- فرق: امسح نظير الصفوف المتغيّرة محليًا وحطها من السحابة
        execute format(
          'delete from public.%I where %I in (select %I from cloudsrc.%I where %I >= %L)',
          r.t, v_pk, v_pk, r.t, v_ts, v_since);
        execute format(
          'insert into public.%I (%s)%sselect %s from cloudsrc.%I where %I >= %L',
          r.t, v_cols, v_over, v_cols, r.t, v_ts, v_since);
      end if;

      execute format('select count(*) from public.%I', r.t) into v_after;
      insert into public.cloud_sync_log(mode,tbl,rows_before,rows_after,seconds,status,detail)
        values (v_mode, r.t, v_before, v_after,
                round(extract(epoch from clock_timestamp() - v_t0)::numeric, 1),
                'ok', coalesce(v_ts, 'كامل'));
      v_done := v_done + 1;
      if v_after <> v_before then
        raise notice '  ✓ %  % → %  (% ث)', rpad(r.t, 30), v_before, v_after,
          round(extract(epoch from clock_timestamp() - v_t0)::numeric, 1);
      end if;

    exception when others then
      insert into public.cloud_sync_log(mode,tbl,rows_before,seconds,status,detail)
        values (v_mode, r.t, v_before,
                round(extract(epoch from clock_timestamp() - v_t0)::numeric, 1),
                'fail', left(sqlerrm, 200));
      v_fail := v_fail + 1;
      raise notice '  ✗ %  %', rpad(r.t, 30), left(sqlerrm, 120);
    end;
  end loop;

  raise notice '═══ تمام: %  ·  اتخطّى: %  ·  فشل: %  ═══', v_done, v_skip, v_fail;
end $sync$;

-- ── السيكوينسات: لازم تتعدّى آخر id اتنقل، وإلا أول إدخال بيصطدم ──
do $seq$
declare r record; v_max bigint; v_fixed int := 0;
begin
  for r in
    select s.relname::text as seq, t.relname::text as tbl, a.attname::text as col
    from pg_class s
    join pg_namespace n on n.oid = s.relnamespace and n.nspname = 'public'
    join pg_depend d on d.objid = s.oid and d.deptype in ('a','i')
    join pg_class t on t.oid = d.refobjid
    join pg_attribute a on a.attrelid = t.oid and a.attnum = d.refobjsubid
    where s.relkind = 'S'
  loop
    begin
      execute format('select max(%I) from public.%I', r.col, r.tbl) into v_max;
      if v_max is not null then
        execute format('select setval(%L, %s)', 'public.' || r.seq, v_max);
        v_fixed := v_fixed + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  raise notice '═══ اتظبط % سيكوينس ═══', v_fixed;
end $seq$;

\echo ''
\echo '════ نتيجة آخر تشغيل ════'
select tbl as "الجدول", rows_before as "قبل", rows_after as "بعد",
       rows_after - rows_before as "الفرق", seconds as "ثواني", detail as "بعمود"
from public.cloud_sync_log
where ran_at > now() - interval '2 hours' and status = 'ok'
  and rows_after is distinct from rows_before
order by abs(rows_after - rows_before) desc nulls last;

\echo ''
\echo '════ فشل (لو فيه) ════'
select tbl as "الجدول", detail as "السبب"
from public.cloud_sync_log
where ran_at > now() - interval '2 hours' and status <> 'ok';
