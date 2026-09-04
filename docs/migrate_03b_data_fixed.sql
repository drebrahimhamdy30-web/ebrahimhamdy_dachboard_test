-- ═══════════════════════════════════════════════════════════════════
-- خطوة 3-ب: نقل البيانات — النسخة المصحّحة
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ شغّله مرة ورا مرة لحد ما يقول «خلصت». الجداول اللي نجحت مش
--    بتتعاد — 57 جدول و406 ألف صف اتنقلوا خلاص.
--
-- إصلاحان:
--
-- 1) `disable trigger all` كان بيحاول يعطّل تريجرات المفاتيح الأجنبية
--    الداخلية وده محتاج superuser. بقى `disable trigger user` — بيعطّل
--    تريجراتنا بس (إشعارات الطيارين ونداءات Edge) وده اللي يهمنا،
--    وصلاحية مالك الجدول تكفيه.
--    ⚠️ بس كده فحص المفاتيح الأجنبية فضل شغّال، يعني **الترتيب بقى
--       مهم**: الابن مايتحملش قبل الأب. الحل: السكربت بيلف على الجداول
--       عدة مرات — اللي يفشل بسبب أب لسه مااتحملش، ينجح في اللفة اللي
--       بعدها. بيوقف لما مفيش تقدّم.
--
-- 2) أعمدة `generated always as identity` مابتقبلش قيمة صريحة.
--    السكربت بيكتشفها ويضيف `overriding system value` للجداول اللي
--    فيها بس.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

do $fs$
begin
  begin alter server cloud options (add fetch_size '20000');
  exception when others then
    begin alter server cloud options (set fetch_size '20000'); exception when others then null; end;
  end;
end $fs$;

-- الجداول الخارجية (لو السكيما موجودة من قبل مابنعملهاش تاني)
do $imp$
begin
  if not exists (select 1 from pg_namespace where nspname = 'cloudsrc') then
    create schema cloudsrc;
    execute 'import foreign schema public from server cloud into cloudsrc';
  end if;
end $imp$;

create table if not exists public.migration_data_log (
  tbl text primary key, rows_moved bigint, ok boolean, err text,
  done_at timestamptz default now()
);

do $mig$
declare
  r         record;
  cols      text;
  ovr       text;
  n         bigint;
  started   timestamptz := clock_timestamp();
  budget    interval := interval '25 seconds';
  pass      int := 0;
  moved     int;
  total     int := 0;
begin
  -- لفّات متتالية: كل لفّة بتحمّل اللي أبوه اتحمّل
  loop
    pass  := pass + 1;
    moved := 0;

    for r in
      select ft.relname as tbl
      from pg_class ft join pg_namespace fn on fn.oid = ft.relnamespace
      where fn.nspname = 'cloudsrc' and ft.relkind = 'f'
        and ft.relname not like 'v\_migration\_%'
        and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid = lc.relnamespace
                    where ln.nspname = 'public' and lc.relkind = 'r' and lc.relname = ft.relname)
        and not exists (select 1 from public.migration_data_log l where l.tbl = ft.relname and l.ok)
      order by ft.relname
    loop
      exit when clock_timestamp() - started > budget;

      -- أعمدة الجدول من ناحية السحابة
      select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
      from pg_attribute a join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'cloudsrc' and c.relname = r.tbl
        and a.attnum > 0 and not a.attisdropped;

      -- فيه عمود generated always as identity؟
      select case when exists (
        select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = r.tbl
          and a.attnum > 0 and not a.attisdropped and a.attidentity = 'a'
      ) then ' overriding system value' else '' end into ovr;

      begin
        -- تريجراتنا بس — مش تريجرات المفاتيح الأجنبية الداخلية
        execute format('alter table public.%I disable trigger user', r.tbl);
        execute format('delete from public.%I', r.tbl);
        execute format('insert into public.%I (%s)%s select %s from cloudsrc.%I',
                       r.tbl, cols, ovr, cols, r.tbl);
        get diagnostics n = row_count;
        execute format('alter table public.%I enable trigger user', r.tbl);

        insert into public.migration_data_log(tbl, rows_moved, ok, err)
          values (r.tbl, n, true, null)
          on conflict (tbl) do update
            set rows_moved = excluded.rows_moved, ok = true, err = null, done_at = now();
        moved := moved + 1; total := total + 1;
      exception when others then
        begin execute format('alter table public.%I enable trigger user', r.tbl); exception when others then null; end;
        insert into public.migration_data_log(tbl, rows_moved, ok, err)
          values (r.tbl, 0, false, sqlstate || ': ' || left(sqlerrm, 250))
          on conflict (tbl) do update set ok = false, err = excluded.err, done_at = now();
      end;
    end loop;

    -- وقفنا لما مفيش تقدّم في اللفّة، أو الوقت خلص
    exit when moved = 0 or clock_timestamp() - started > budget or pass > 12;
  end loop;

  raise notice 'اتنقل في التشغيلة دي: % جدول (% لفّة)', total, pass;
end $mig$;

-- ── الحالة ──────────────────────────────────────────────────────
with pending as (
  select ft.relname
  from pg_class ft join pg_namespace fn on fn.oid = ft.relnamespace
  where fn.nspname = 'cloudsrc' and ft.relkind = 'f'
    and ft.relname not like 'v\_migration\_%'
    and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid = lc.relnamespace
                where ln.nspname = 'public' and lc.relkind = 'r' and lc.relname = ft.relname)
    and not exists (select 1 from public.migration_data_log l where l.tbl = ft.relname and l.ok)
)
select case when (select count(*) from pending) = 0
            then '🎉 خلصت — كل الجداول اتنقلت'
            else '⏳ شغّله تاني — فاضل ' || (select count(*) from pending)::text || ' جدول' end as الحالة,
       (select count(*) from public.migration_data_log where ok)                        as جداول_تمّت,
       (select coalesce(sum(rows_moved),0) from public.migration_data_log where ok)     as صفوف_اتنقلت,
       (select coalesce(string_agg(relname, ', ' order by relname), '—') from pending)  as الفاضل;
