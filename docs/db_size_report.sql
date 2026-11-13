-- ═══════════════════════════════════════════════════════════════════
--  تقرير حجم القاعدة والنمو الشهري
-- ═══════════════════════════════════════════════════════════════════
--  يتشغّل في SQL Editor على السحابة (أو psql على الذاتي). قراءة فقط
--  ما عدا الدالة في الجزء ٣ — وهي دالة تقرير، مش بتلمس بيانات.
--
--  ⚠️ `reltuples` **تقديري** مش عدّ حقيقي: بيتحدّث مع ANALYZE/autovacuum.
--     لجدول اتغيّر كتير من غير vacuum الرقم بيبوظ. لو محتاج دقّة في
--     جدول معيّن اعمله `analyze <table>;` الأول، أو عدّ بـ`count(*)`.
--
--  ⚠️ حجم القاعدة ده **مش** كل اللي سوبابيز بتحسبه عليك: التخزين
--     (buckets) والنسخ الاحتياطية بره الرقم ده. بُص على Database →
--     Reports في اللوحة للصورة الكاملة.
-- ═══════════════════════════════════════════════════════════════════

-- ═══ ١ — الحجم الكلي ═══
select pg_size_pretty(pg_database_size(current_database())) as "حجم القاعدة";

-- ═══ ٢ — أكبر ٣٠ جدول: الحجم، الصفوف، وحجم الصف الواحد ═══
select
  n.nspname || '.' || c.relname                   as "الجدول",
  pg_size_pretty(pg_total_relation_size(c.oid))   as "الإجمالي",
  pg_size_pretty(pg_relation_size(c.oid))         as "البيانات",
  pg_size_pretty(pg_indexes_size(c.oid))          as "الفهارس",
  c.reltuples::bigint                             as "صفوف (تقديري)",
  case when c.reltuples > 0
       then pg_size_pretty((pg_total_relation_size(c.oid) / c.reltuples)::bigint)
  end                                             as "حجم الصف"
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','m')
  and n.nspname not in ('pg_catalog','information_schema','pg_toast')
order by pg_total_relation_size(c.oid) desc
limit 30;

-- ═══ ٣ — النمو بالشهور ═══
/* بتمشي على كل جدول أكبر من ٨ ميجا، بتلاقي أول عمود وقت فيه
   (بتفضّل created_at ثم bill_date)، وبتعدّ الصفوف بالشهر.
   الحجم التقديري = عدد صفوف الشهر × متوسط حجم الصف في الجدول —
   تقريب مقبول للاتجاه، مش رقم محاسبي. */
set time zone 'Africa/Cairo';

create or replace function public.db_growth_by_month(p_months int default 12)
/* ⚠️ **مش** SECURITY DEFINER عن قصد: الدالة بتنفّذ SQL ديناميكي على
   أي جدول في public، فلو كانت DEFINER ومتاحة لـauthenticated تبقى
   باب تصعيد صلاحيات. بتتشغّل من SQL Editor بصلاحية المالك وخلاص. */
returns table(tbl text, ym text, n_rows bigint, bytes bigint)
language plpgsql set search_path = public as $$
declare r record; v_col text; v_row_bytes bigint;
begin
  for r in
    select c.oid, c.relname, c.reltuples, pg_total_relation_size(c.oid) as total
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'r' and n.nspname = 'public'
      and pg_total_relation_size(c.oid) > 8 * 1024 * 1024
    order by pg_total_relation_size(c.oid) desc
  loop
    select a.attname into v_col
    from pg_attribute a
    join pg_type t on t.oid = a.atttypid
    where a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped
      and t.typname in ('timestamptz','timestamp','date')
    order by case a.attname
               when 'created_at'  then 0
               when 'bill_date'   then 1
               when 'inserted_at' then 2
               when 'synced_at'   then 8   -- ⚠️ ده وقت المزامنة مش وقت الحدث
               else 5 end, a.attnum
    limit 1;
    if v_col is null then continue; end if;   -- جدول بلا عمود وقت (مرجعي غالبًا)

    v_row_bytes := case when r.reltuples > 0 then (r.total / r.reltuples)::bigint else 0 end;

    return query execute format(
      'select %L::text, to_char(%I::date, ''YYYY-MM''), count(*)::bigint,
              (count(*) * %s)::bigint
         from public.%I
        where %I >= (date_trunc(''month'', current_date) - interval ''%s months'')
        group by 2 order by 2',
      r.relname, v_col, v_row_bytes, r.relname, v_col, p_months);
  end loop;
end $$;

revoke all on function public.db_growth_by_month(int) from public;

-- الملخّص: إجمالي النمو لكل شهر (ده اللي بيجاوب «الحجم بالشهور»)
select ym                              as "الشهر",
       sum(n_rows)                     as "صفوف اتضافت",
       pg_size_pretty(sum(bytes))      as "حجم تقديري"
from public.db_growth_by_month(12)
group by ym order by ym;

-- التفصيل: مين بالظبط اللي بيكبّر القاعدة، جدول × شهر
select tbl                        as "الجدول",
       ym                         as "الشهر",
       n_rows                     as "صفوف الشهر",
       pg_size_pretty(bytes)      as "حجم تقديري"
from public.db_growth_by_month(12)
order by tbl, ym;

-- أكتر ١٠ جداول نموًا في آخر ٣ شهور
select tbl                        as "الجدول",
       sum(n_rows)                as "صفوف ٣ شهور",
       pg_size_pretty(sum(bytes)) as "حجم تقديري"
from public.db_growth_by_month(3)
group by tbl order by sum(bytes) desc nulls last limit 10;
