-- ═══════════════════════════════════════════════════════════════════
--  بصمة السكيما — للمقارنة بين السيرفر الذاتي والسحابة
-- ═══════════════════════════════════════════════════════════════════
--  بيقرا بس، مابيغيّرش أي حاجة. بيطلّع ١٠ سطور: العدد + بصمة قصيرة
--  لكل نوع. لو البصمة زي بعضها في الجهتين → النوع ده مطابق تمامًا.
--  لو مختلفة → نغوص في النوع ده لوحده بدل ما نقارن ٢٠٠ دالة بالعين.
--
--  على السيرفر:
--    CID=$(docker compose ps -q db)
--    docker exec -i $CID psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/schema_fingerprint.sql
--
--  على السحابة: SQL Editor.
-- ═══════════════════════════════════════════════════════════════════

with sig as (
  select 'جداول' as نوع, 1 as ت, array_agg(c.relname::text order by c.relname) as ق
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'

  union all
  select 'أعمدة', 2, array_agg(t || '.' || col order by t, col)
  from (
    select c.relname::text as t, a.attname::text as col
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and a.attnum > 0 and not a.attisdropped
  ) x

  union all
  select 'دوال', 3, array_agg(p.proname::text || '(' || pg_get_function_identity_arguments(p.oid) || ')'
                              order by p.proname, pg_get_function_identity_arguments(p.oid))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'

  union all
  select 'تريجرات', 4, array_agg(c.relname::text || '.' || t.tgname::text order by c.relname, t.tgname)
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not t.tgisinternal

  union all
  select 'فهارس', 5, array_agg(indexname::text order by indexname)
  from pg_indexes where schemaname = 'public'

  union all
  select 'قيود', 6, array_agg(c.relname::text || '.' || con.conname::text order by c.relname, con.conname)
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'

  union all
  select 'سياسات RLS', 7, array_agg(tablename::text || '.' || policyname::text order by tablename, policyname)
  from pg_policies where schemaname = 'public'

  union all
  select 'views', 8, array_agg(viewname::text order by viewname)
  from pg_views where schemaname = 'public'

  union all
  select 'أنواع enum', 9, array_agg(t.typname::text order by t.typname)
  from pg_type t join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typtype = 'e'

)
select ت as "#", نوع, coalesce(array_length(ق, 1), 0) as العدد,
       left(md5(coalesce(array_to_string(ق, '|'), '')), 8) as البصمة
from sig
order by ت;

-- مهام الكرون منفصلة: لو pg_cron مش متركّب على السيرفر الاستعلام كله كان
-- هيفشل (بوستجرس بيحلّل الجملة كلها قبل ما ينفّذها)، فخليناها لوحدها.
-- لو ردّت خطأ «relation cron.job does not exist» يبقى مفيش pg_cron — وده متوقّع.
select count(*) as "مهام cron" from cron.job;
