-- ═══════════════════════════════════════════════════════════════════
-- خطوة 3-ج: نقل البيانات — نسخة خفيفة على واجهة Studio
-- ═══════════════════════════════════════════════════════════════════
-- واجهة Studio بتقع على الطلبات الطويلة (خطأ JavaScript عندها، مش في
-- الاستعلام). النسخة دي:
--   · مدة 10 ثواني بس بدل 25
--   · من غير raise notice (الواجهة بتتعثّر في قراءة الإشعارات)
--   · مخرجات سطر واحد قصير
--
-- ⚠️ شغّله مرة ورا مرة. لو الواجهة وقعت، اعمل Reload وشغّله تاني —
--    الشغل بيتحفظ فعلًا، الوقوع في العرض بس.
-- ⚠️ الجداول اللي نجحت مش بتتعاد.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

do $mig$
declare
  r        record;
  cols     text;
  ovr      text;
  n        bigint;
  started  timestamptz := clock_timestamp();
  moved    int;
begin
  loop
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
      exit when clock_timestamp() - started > interval '10 seconds';

      select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
      from pg_attribute a join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'cloudsrc' and c.relname = r.tbl
        and a.attnum > 0 and not a.attisdropped;

      select case when exists (
        select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = r.tbl
          and a.attnum > 0 and not a.attisdropped and a.attidentity = 'a'
      ) then ' overriding system value' else '' end into ovr;

      begin
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
        moved := moved + 1;
      exception when others then
        begin execute format('alter table public.%I enable trigger user', r.tbl); exception when others then null; end;
        insert into public.migration_data_log(tbl, rows_moved, ok, err)
          values (r.tbl, 0, false, sqlstate || ': ' || left(sqlerrm, 200))
          on conflict (tbl) do update set ok = false, err = excluded.err, done_at = now();
      end;
    end loop;
    exit when moved = 0 or clock_timestamp() - started > interval '10 seconds';
  end loop;
end $mig$;

select (select count(*) from public.migration_data_log where ok)                    as تمّت,
       (select coalesce(sum(rows_moved),0) from public.migration_data_log where ok)  as صفوف,
       (select count(*) from pg_class ft join pg_namespace fn on fn.oid=ft.relnamespace
        where fn.nspname='cloudsrc' and ft.relkind='f' and ft.relname not like 'v\_migration\_%'
          and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid=lc.relnamespace
                      where ln.nspname='public' and lc.relkind='r' and lc.relname=ft.relname)
          and not exists (select 1 from public.migration_data_log l where l.tbl=ft.relname and l.ok)) as فاضل;
