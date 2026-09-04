-- ═══════════════════════════════════════════════════════════════════
-- خطوة 1: نقل السكيما كاملة من السحابة للسيرفر
-- ═══════════════════════════════════════════════════════════════════
-- شغّله في SQL Editor بتاع supabase.ebrahimhamdy.com
--
-- بيسحب 1396 أمر من فيو على السحابة وينفّذهم بالترتيب:
--   إضافات → سيكوينسات → جداول → قيود → مفاتيح أجنبية → فهارس →
--   دوال → فيوهات → تريجرات → RLS → سياسات → صلاحيات
--
-- ⚠️ الترتيب مقصود: جداول قبل القيود، دوال قبل التريجرات اللي بتناديها.
--
-- ⚠️ **مافيش بيانات هنا** — الهيكل بس. البيانات في الخطوة اللي بعدها.
--
-- ⚠️ الأمر مابيقفش عند أول خطأ — بيسجّل كل حاجة في public.migration_log
--    ويكمّل، وفي الآخر بيطلّع ملخّص. ده مقصود عشان نشوف كل المشاكل مرة
--    واحدة بدل ما نلف 20 مرة.
--
-- ⚠️ حط الباسورد مكان «الباسورد-هنا» — **من غير أقواس < >**.
--    لو الباسورد فيه علامة تنصيص مفردة ' كرّرها مرتين ''.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1) الاتصال بالسحابة ──────────────────────────────────────────
create extension if not exists postgres_fdw;
create extension if not exists dblink;

drop server if exists cloud cascade;
create server cloud
  foreign data wrapper postgres_fdw
  options (host 'aws-0-eu-west-1.pooler.supabase.com', port '5432',
           dbname 'postgres', sslmode 'require');

create user mapping for public server cloud
  options (user 'postgres.rxtjoqulmgkkcohmgzgi', password 'الباسورد-هنا');

drop schema if exists cloudsrc cascade;
create schema cloudsrc;
import foreign schema public
  limit to (v_migration_ddl, v_migration_post)
  from server cloud into cloudsrc;

-- ── 2) سجل التنفيذ ──────────────────────────────────────────────
create table if not exists public.migration_log (
  id      bigserial primary key,
  ord     int,
  kind    text,
  obj     text,
  ok      boolean,
  err     text,
  ran_at  timestamptz default now()
);
truncate public.migration_log;

-- ── 3) التنفيذ ──────────────────────────────────────────────────
do $mig$
declare
  r record;
  n_ok int := 0;
  n_err int := 0;
  -- رابط السيرفر ده — بيحلّ محل __TARGET_URL__ في الدوال اللي بتنده
  -- Edge Functions. من غيره هيفضلوا ينادوا **السحابة**.
  target_url text := 'https://supabase.ebrahimhamdy.com';
begin
  for r in select ord, kind, obj, ddl from cloudsrc.v_migration_ddl order by ord, obj loop
    begin
      execute replace(r.ddl, '__TARGET_URL__', target_url);
      insert into public.migration_log(ord, kind, obj, ok) values (r.ord, r.kind, r.obj, true);
      n_ok := n_ok + 1;
    exception when others then
      insert into public.migration_log(ord, kind, obj, ok, err)
        values (r.ord, r.kind, r.obj, false, sqlstate || ': ' || left(sqlerrm, 200));
      n_err := n_err + 1;
    end;
  end loop;
  raise notice 'نجح % / فشل %', n_ok, n_err;
end $mig$;

-- ── 4) الملخّص ──────────────────────────────────────────────────
select kind as النوع,
       count(*) filter (where ok)      as نجح,
       count(*) filter (where not ok)  as فشل
from public.migration_log
group by kind, ord order by ord;

select count(*) filter (where ok) as إجمالي_نجح,
       count(*) filter (where not ok) as إجمالي_فشل
from public.migration_log;

-- ── 5) أول 40 خطأ (لو فيه) ──────────────────────────────────────
select kind as النوع, obj as الكائن, err as الخطأ
from public.migration_log where not ok order by ord, obj limit 40;
