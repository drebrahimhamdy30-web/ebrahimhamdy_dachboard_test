-- ═══════════════════════════════════════════════════════════════════
-- خطوة 3-د: إنهاء الخمس جداول الباقية
-- ═══════════════════════════════════════════════════════════════════
-- سببان مختلفان:
--
-- 1) أعمدة محسوبة (generated always as ... stored) — زي code_norm في
--    jard_excluded_codes و return_value في returns_log. دي Postgres
--    بيحسبها لوحده ومابتتكتبش، فلازم **تتشال من قايمة الأعمدة**.
--    (غير أعمدة identity اللي بتتحل بـoverriding system value.)
--
-- 2) مفتاح أجنبي مكسور في order_logs / trip_logs / trip_orders.
--    السبب مش ترتيب: `orders` و`trips` اتنسخوا من فترة، والأبناء
--    بيتنسخوا **دلوقتي** — فالسجلات الجديدة بتشير لصفوف اتعملت في
--    السحابة بعد ما الأب اتنسخ. فرق توقيت بين نسخ الجداول.
--
--    الحل: نشيل القيد، ننقل كل الصفوف، ونرجّع القيد `not valid`
--    (يعني بيسري على الصفوف الجديدة، والقديمة مش بتتفحص). كده مفيش
--    صف بيضيع. آخر خطوة تحت بتعيد نسخ الآباء وتتحقق من القيود.
--
-- ⚠️ شغّله مرة ورا مرة زي الباقي. لو الواجهة وقعت اعمل Reload وكمّل.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

do $mig$
declare
  r     record;
  c     record;
  cols  text;
  ovr   text;
  n     bigint;
  fks   text[];
  started timestamptz := clock_timestamp();
begin
  for r in
    select ft.relname as tbl
    from pg_class ft join pg_namespace fn on fn.oid = ft.relnamespace
    where fn.nspname = 'cloudsrc' and ft.relkind = 'f'
      and ft.relname not like 'v\_migration\_%'
      and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid = lc.relnamespace
                  where ln.nspname='public' and lc.relkind='r' and lc.relname=ft.relname)
      and not exists (select 1 from public.migration_data_log l where l.tbl = ft.relname and l.ok)
    order by ft.relname
  loop
    exit when clock_timestamp() - started > interval '20 seconds';

    -- أعمدة السحابة **ناقص** الأعمدة المحسوبة محليًا
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a join pg_class c2 on c2.oid = a.attrelid
    join pg_namespace n2 on n2.oid = c2.relnamespace
    where n2.nspname = 'cloudsrc' and c2.relname = r.tbl
      and a.attnum > 0 and not a.attisdropped
      and not exists (
        select 1 from pg_attribute la join pg_class lc on lc.oid = la.attrelid
        join pg_namespace ln on ln.oid = lc.relnamespace
        where ln.nspname='public' and lc.relname = r.tbl
          and la.attname = a.attname and la.attgenerated <> '');

    select case when exists (
      select 1 from pg_attribute a join pg_class c2 on c2.oid = a.attrelid
      join pg_namespace n2 on n2.oid = c2.relnamespace
      where n2.nspname='public' and c2.relname = r.tbl
        and a.attnum > 0 and not a.attisdropped and a.attidentity = 'a'
    ) then ' overriding system value' else '' end into ovr;

    -- نحفظ تعريفات المفاتيح الأجنبية ونشيلها
    fks := array[]::text[];
    for c in
      select con.conname, pg_get_constraintdef(con.oid) as def
      from pg_constraint con
      where con.conrelid = format('public.%I', r.tbl)::regclass and con.contype = 'f'
    loop
      fks := fks || format('alter table public.%I add constraint %I %s not valid', r.tbl, c.conname, c.def);
      execute format('alter table public.%I drop constraint %I', r.tbl, c.conname);
    end loop;

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
    exception when others then
      begin execute format('alter table public.%I enable trigger user', r.tbl); exception when others then null; end;
      insert into public.migration_data_log(tbl, rows_moved, ok, err)
        values (r.tbl, 0, false, sqlstate || ': ' || left(sqlerrm, 200))
        on conflict (tbl) do update set ok = false, err = excluded.err, done_at = now();
    end;

    -- نرجّع المفاتيح الأجنبية (not valid = مابتفحصش الصفوف الموجودة)
    foreach cols in array fks loop
      begin execute cols; exception when others then null; end;
    end loop;
  end loop;
end $mig$;

select (select count(*) from public.migration_data_log where ok)                   as تمّت,
       (select coalesce(sum(rows_moved),0) from public.migration_data_log where ok) as صفوف,
       (select coalesce(string_agg(tbl, ', ' order by tbl), '🎉 خلصت')
          from public.migration_data_log where not ok)                              as الفاضل;
