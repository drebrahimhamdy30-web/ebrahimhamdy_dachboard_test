-- ═══════════════════════════════════════════════════════════════════
-- خطوة 3: نقل البيانات (629 ميجا / ~881 ألف صف)
-- ═══════════════════════════════════════════════════════════════════
-- شغّله في SQL Editor بتاع supabase.ebrahimhamdy.com
--
-- ⚠️⚠️ **شغّله أكتر من مرة لحد ما يقول «خلصت»** ⚠️⚠️
--   بوابة Studio بتقطع الطلبات الطويلة، فالسكربت بيشتغل ~40 ثانية
--   وبيقف بنظافة ويسجّل مكانه. كل تشغيلة بتكمّل من حيث وقفت.
--
-- ⚠️ **الفخ الأخطر: التريجرات.**
--   `orders` عليها تريجرات بتبعت إشعارات للطيارين وبتنده Edge Functions.
--   نقل 23 ألف طلب من غير تعطيلها = آلاف الإشعارات على تليفونات
--   الطيارين الحقيقيين + آلاف النداءات. السكربت بيعطّل **كل** التريجرات
--   (وده بيعطّل فحص المفاتيح الأجنبية كمان فالترتيب مايفرقش) وبيرجّعها
--   في الآخر.
--
-- ⚠️ كل جدول بيتفضّى (truncate) قبل ما يتملى — فالتشغيل المتكرر آمن
--   ومابيكرّرش صفوف.
-- ═══════════════════════════════════════════════════════════════════

-- ── إعداد لمرة واحدة ────────────────────────────────────────────
set statement_timeout = 0;

-- جلب أسرع من السحابة (الافتراضي 100 صف/دفعة = بطيء جدًا لـ150 ألف صف)
-- ⚠️ `set` بيفشل لو الخيار مش متسجّل قبل كده، و`add` بيفشل لو متسجّل.
--    فبنجرّب الاتنين.
do $fs$
begin
  begin
    alter server cloud options (add fetch_size '20000');
  exception when others then
    alter server cloud options (set fetch_size '20000');
  end;
end $fs$;

-- كل جداول السحابة كجداول خارجية
drop schema if exists cloudsrc cascade;
create schema cloudsrc;
import foreign schema public from server cloud into cloudsrc;

create table if not exists public.migration_data_log (
  tbl        text primary key,
  rows_moved bigint,
  ok         boolean,
  err        text,
  done_at    timestamptz default now()
);

-- ── النقل ───────────────────────────────────────────────────────
do $mig$
declare
  r        record;
  cols     text;
  n        bigint;
  started  timestamptz := clock_timestamp();
  budget   interval := interval '40 seconds';
  did      int := 0;
  remaining int;
begin
  for r in
    select ft.relname as tbl
    from pg_class ft
    join pg_namespace fn on fn.oid = ft.relnamespace
    where fn.nspname = 'cloudsrc' and ft.relkind = 'f'
      and ft.relname not like 'v\_migration\_%'
      -- الجدول موجود محليًا كجدول حقيقي
      and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid = lc.relnamespace
                  where ln.nspname = 'public' and lc.relkind = 'r' and lc.relname = ft.relname)
      -- ولسه ماتنقلش
      and not exists (select 1 from public.migration_data_log l where l.tbl = ft.relname and l.ok)
    order by ft.relname
  loop
    -- نوقف قبل ما نبدأ جدول جديد لو الوقت قرب يخلص
    exit when clock_timestamp() - started > budget;

    -- أعمدة الجدول **من ناحية السحابة** (السيرفر ممكن يكون عنده زيادة)
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'cloudsrc' and c.relname = r.tbl
      and a.attnum > 0 and not a.attisdropped;

    begin
      -- ⚠️ تعطيل التريجرات: إشعارات الطيارين + نداءات Edge + فحص المفاتيح
      execute format('alter table public.%I disable trigger all', r.tbl);
      execute format('truncate table public.%I', r.tbl);
      execute format('insert into public.%I (%s) select %s from cloudsrc.%I', r.tbl, cols, cols, r.tbl);
      get diagnostics n = row_count;
      execute format('alter table public.%I enable trigger all', r.tbl);

      insert into public.migration_data_log(tbl, rows_moved, ok)
        values (r.tbl, n, true)
        on conflict (tbl) do update set rows_moved = excluded.rows_moved, ok = true, err = null, done_at = now();
      did := did + 1;
    exception when others then
      begin execute format('alter table public.%I enable trigger all', r.tbl); exception when others then null; end;
      insert into public.migration_data_log(tbl, rows_moved, ok, err)
        values (r.tbl, 0, false, sqlstate || ': ' || left(sqlerrm, 250))
        on conflict (tbl) do update set ok = false, err = excluded.err, done_at = now();
    end;
  end loop;

  select count(*) into remaining
  from pg_class ft join pg_namespace fn on fn.oid = ft.relnamespace
  where fn.nspname = 'cloudsrc' and ft.relkind = 'f'
    and ft.relname not like 'v\_migration\_%'
    and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid = lc.relnamespace
                where ln.nspname='public' and lc.relkind='r' and lc.relname=ft.relname)
    and not exists (select 1 from public.migration_data_log l where l.tbl = ft.relname and l.ok);

  raise notice 'اتنقل دلوقتي: % جدول · فاضل: %', did, remaining;
end $mig$;

-- ── الحالة ──────────────────────────────────────────────────────
select
  case when (select count(*) from pg_class ft join pg_namespace fn on fn.oid=ft.relnamespace
             where fn.nspname='cloudsrc' and ft.relkind='f'
               and ft.relname not like 'v\_migration\_%'
               and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid=lc.relnamespace
                           where ln.nspname='public' and lc.relkind='r' and lc.relname=ft.relname)
               and not exists (select 1 from public.migration_data_log l where l.tbl=ft.relname and l.ok)) = 0
       then '🎉 خلصت — كل الجداول اتنقلت'
       else '⏳ شغّل الملف تاني — فاضل ' ||
            (select count(*)::text from pg_class ft join pg_namespace fn on fn.oid=ft.relnamespace
             where fn.nspname='cloudsrc' and ft.relkind='f'
               and ft.relname not like 'v\_migration\_%'
               and exists (select 1 from pg_class lc join pg_namespace ln on ln.oid=lc.relnamespace
                           where ln.nspname='public' and lc.relkind='r' and lc.relname=ft.relname)
               and not exists (select 1 from public.migration_data_log l where l.tbl=ft.relname and l.ok)) || ' جدول'
  end as الحالة,
  (select count(*) from public.migration_data_log where ok)      as جداول_تمّت,
  (select coalesce(sum(rows_moved),0) from public.migration_data_log where ok) as صفوف_اتنقلت,
  (select count(*) from public.migration_data_log where not ok)  as فشل;

-- أخطاء لو فيه
select tbl as الجدول, err as الخطأ from public.migration_data_log where not ok order by tbl;
