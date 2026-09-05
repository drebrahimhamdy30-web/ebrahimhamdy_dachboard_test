-- ═══════════════════════════════════════════════════════════════════
-- خطوة 4-ب: السيكوينسات — النسخة المصحّحة
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ الخطأ اللي حصل: «cannot open relation http_header — composite types».
--    السبب: Postgres مش مضمون يطبّق فلتر relkind='S' **قبل** ما ينادي
--    pg_sequence_last_value. وسكيما public على السيرفر فيها أنواع
--    مركّبة (من إضافة http اللي اتثبتت في public) — فالدالة اتنادت
--    على نوع مش سيكوينس ووقعت.
--    الحل: CTE **materialized** يفلتر الأول ويجبر التنفيذ بالترتيب.
--    (نفس الفخ قابلني وأنا بعمل الفيو على السحابة.)
--
-- ⚠️ آمن للتشغيل المتكرر.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

-- ── 1) ربط كل سيكوينس بعموده + ضبط قيمته من السحابة ─────────────
do $seq$
declare r record; n_ok int := 0; n_err int := 0; last_err text := '';
begin
  for r in select ord, kind, obj, ddl from cloudsrc.v_migration_post
           where kind in ('seq_owner','setval') order by ord, obj
  loop
    begin
      execute r.ddl;
      n_ok := n_ok + 1;
    exception when others then
      n_err := n_err + 1;
      last_err := r.obj || ' → ' || sqlstate || ': ' || left(sqlerrm, 120);
    end;
  end loop;
  if n_err > 0 then raise notice 'فشل %: %', n_err, last_err; end if;
end $seq$;

-- ── 2) التحقق (بـCTE materialized عشان الفلتر يتنفّذ الأول) ──────
with seqs as materialized (
  select s.oid, s.relname
  from pg_class s join pg_namespace n on n.oid = s.relnamespace
  where n.nspname = 'public' and s.relkind = 'S'
),
vals as (
  select relname, pg_sequence_last_value(oid) as lv from seqs
)
select count(*)                                   as إجمالي_السيكوينسات,
       count(*) filter (where lv is not null)      as متظبّطة,
       count(*) filter (where lv is null)          as لسه_على_البداية
from vals;
