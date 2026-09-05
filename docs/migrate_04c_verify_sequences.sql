-- ═══════════════════════════════════════════════════════════════════
-- تحقق قاطع: هل أي سيكوينس هيصطدم عند أول إضافة جديدة؟
-- ═══════════════════════════════════════════════════════════════════
-- بيقارن قيمة كل سيكوينس بأكبر قيمة فعلية في عموده.
-- ⚠️ CTE materialized إجباري — public فيها أنواع مركّبة (من إضافة http)
--    و pg_sequence_last_value بتقع عليها لو الفلتر ماتنفّذش الأول.
-- قراءة بس.
-- ═══════════════════════════════════════════════════════════════════
with seqs as materialized (
  select s.oid, s.relname as seq, t.relname as tbl, a.attname as col
  from pg_class s
  join pg_namespace n on n.oid = s.relnamespace and n.nspname = 'public'
  join pg_depend d on d.objid = s.oid and d.deptype = 'a'
  join pg_class t on t.oid = d.refobjid and t.relkind = 'r'
  join pg_attribute a on a.attrelid = t.oid and a.attnum = d.refobjsubid
  where s.relkind = 'S'
),
chk as materialized (
  select seq, tbl, col, coalesce(pg_sequence_last_value(oid), 0) as seq_val from seqs
)
select tbl as الجدول, seq_val as قيمة_السيكوينس, max_id as أكبر_id,
       case when max_id is null then '✅ الجدول فاضي'
            when seq_val >= max_id then '✅ سليم'
            else '❌ هيصطدم' end as الحكم
from chk
cross join lateral (
  select (xpath('/row/max/text()',
          query_to_xml(format('select max(%I) as max from public.%I', col, tbl),
                       true, true, '')))[1]::text::numeric as max_id
) m
where max_id is null or seq_val < max_id or seq_val = 0
order by (case when max_id is not null and seq_val < max_id then 0 else 1 end), tbl;
