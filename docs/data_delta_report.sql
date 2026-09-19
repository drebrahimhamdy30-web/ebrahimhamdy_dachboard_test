-- ═══════════════════════════════════════════════════════════════════
--  تقرير فرق البيانات: السيرفر الذاتي مقابل السحابة
-- ═══════════════════════════════════════════════════════════════════
--  بيقرا بس. بيعدّي على كل جدول في public وله نظير في cloudsrc
--  (السكيما المربوطة بالسحابة عبر postgres_fdw) ويقارن عدد الصفوف.
--
--  ليه: بيانات السيرفر من 2026-09-05. عايزين نعرف **إيه** اللي اتغيّر
--  و**قد إيه** قبل ما نقرر ننقل إيه — مش نسحب 116 جدول على البركة.
--
--  ⚠️ العد على السحابة بيمشي عبر الشبكة، فالجداول الكبيرة بتاخد وقت.
--     فيه سقف 90 ثانية لكل جدول؛ اللي يعدّيه بيتسجّل "بطيء" ونتعامل
--     معاه على حدة بدل ما التقرير كله يقف.
--
--  التشغيل (بياخد من 3 لـ10 دقايق):
--    cd /root/supabase-project
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/data_delta_report.sql
-- ═══════════════════════════════════════════════════════════════════

\timing off
\set ON_ERROR_STOP off

drop table if exists _delta;
create temp table _delta(tbl text, srv bigint, cloud bigint, note text);

do $$
declare
  r record; v_srv bigint; v_cloud bigint; v_note text;
begin
  for r in
    select c.relname::text as t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and exists (select 1 from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace
                  where n2.nspname = 'cloudsrc' and c2.relname = c.relname)
    order by c.relname
  loop
    v_note := null;
    execute format('select count(*) from public.%I', r.t) into v_srv;
    begin
      -- السقف بيحمينا من إن جدول واحد كبير يوقف التقرير كله
      set local statement_timeout = '90s';
      execute format('select count(*) from cloudsrc.%I', r.t) into v_cloud;
    exception when others then
      v_cloud := null; v_note := 'بطيء أو فشل: ' || left(sqlerrm, 40);
    end;
    insert into _delta values (r.t, v_srv, v_cloud, v_note);
  end loop;
end $$;

\echo ''
\echo '════ جداول ناقصة صفوف على السيرفر (الأهم) ════'
select tbl as "الجدول", srv as "السيرفر", cloud as "السحابة",
       cloud - srv as "الفرق",
       case when srv = 0 then 'فاضي على السيرفر'
            when cloud::numeric / nullif(srv,0) > 1.5 then 'فرق كبير'
            else '' end as "ملاحظة"
from _delta
where cloud is not null and cloud > srv
order by (cloud - srv) desc;

\echo ''
\echo '════ جداول فيها صفوف زيادة على السيرفر (تجارب أو حذف من السحابة) ════'
select tbl as "الجدول", srv as "السيرفر", cloud as "السحابة", srv - cloud as "الزيادة"
from _delta
where cloud is not null and srv > cloud
order by (srv - cloud) desc;

\echo ''
\echo '════ متطابقة ════'
select count(*) as "عدد الجداول المتطابقة" from _delta where srv = cloud;

\echo ''
\echo '════ ماقدرناش نعدّها (نتعامل معاها على حدة) ════'
select tbl as "الجدول", srv as "السيرفر", note as "السبب" from _delta where cloud is null;
