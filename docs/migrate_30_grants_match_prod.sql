-- ═══════════════════════════════════════════════════════════════════
--  migrate_30 — الصلاحيات على السيرفر تطابق البرودكشن بالظبط
-- ═══════════════════════════════════════════════════════════════════
--  اكتشفه حارس الانحراف (2026-09-19): 196 جدول صلاحياتهم على السيرفر
--  **أوسع** من البرودكشن. مثال:
--      app_control · authenticated
--        السحابة: SELECT, UPDATE
--        السيرفر: DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
--
--  يعني أي موظف مسجّل دخول يقدر يمسح أو يفضّي جداول البرودكشن
--  مابيسمحلهوش يقربلها. و11 دالة كمان صلاحية تنفيذها أوسع.
--
--  السبب: التنصيبة الذاتية فيها `alter default privileges` بيدّي كل
--  جدول جديد صلاحيات كاملة. اتصلح لـanon في سبتمبر و authenticated
--  فضل على حاله — والشاشات اشتغلت عادي لأن الصلاحية الزيادة مابتكسرش
--  حاجة، بس بتفتح باب.
--
--  ⚠️ ليه ده خطير عندنا تحديدًا: سياسات RLS في النظام ده مفتوحة
--     (using true) — فطبقة الجرانت هي **الحارس الوحيد** فعليًا.
--
--  ═══ إيه اللي بيعمله ═══
--  لكل جدول موجود في الجهتين: يسحب صلاحيات anon/authenticated/
--  service_role، وبعدين يديها من جديد **بنفس اللي على السحابة بالظبط**
--  (من v_migration_ddl عبر fdw — مفيش نسخ يدوي).
--
--  ⚠️ جداول السيرفر لوحده (branch_stock_* وإخواتهم) **ماتتلمسش** —
--     مالهاش نظير على السحابة، والسحب منها هيكسّر شغل الفورمات الطولي.
--
--  آمن يتعاد تشغيله.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'cloudsrc' and c.relname = 'v_migration_ddl') then
    execute 'import foreign schema public limit to (v_migration_ddl) from server cloud into cloudsrc';
  end if;
end $$;

BEGIN;

do $g$
declare
  r record;
  n_rev int := 0; n_grant int := 0; n_acl int := 0; n_skip int := 0;
begin
  -- ── 1) سحب الصلاحيات — بس من الجداول اللي ليها نظير على السحابة ──
  for r in
    select c.relname::text as t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and exists (select 1 from cloudsrc.v_migration_ddl v
                  where v.kind = 'table' and v.obj = c.relname)
    order by 1
  loop
    execute format('revoke all on table public.%I from anon, authenticated, service_role', r.t);
    n_rev := n_rev + 1;
  end loop;

  -- ── 2) الإعطاء من جديد بنسخة السحابة بالظبط ──────────────────────
  for r in
    select obj, ddl from cloudsrc.v_migration_ddl where kind = 'grant'
  loop
    begin
      execute r.ddl;
      n_grant := n_grant + 1;
    exception when undefined_table then
      -- جدول على السحابة ومش عندنا (زي جداول النسخ المؤقتة) — عادي
      n_skip := n_skip + 1;
    end;
  end loop;

  -- ── 3) صلاحيات تنفيذ الدوال ─────────────────────────────────────
  -- النص نفسه فيه revoke ثم grant، فبيضبط الزيادة والنقص مرة واحدة
  for r in
    select obj, ddl from cloudsrc.v_migration_ddl where kind = 'fn_acl'
  loop
    begin
      execute r.ddl;
      n_acl := n_acl + 1;
    exception when undefined_function or undefined_table then
      n_skip := n_skip + 1;
    end;
  end loop;

  raise notice '═══ اتسحبت من: % جدول  ·  اتعطت: % صلاحية  ·  دوال: %  ·  اتخطّى: % ═══',
    n_rev, n_grant, n_acl, n_skip;
end $g$;

-- ── 4) الأصل: أي جدول **جديد** مايخدش صلاحيات كاملة تلقائيًا ───────
-- من غير ده، أول جدول نعمله بعد كده هيرجّع نفس المشكلة.
do $d$
declare r record; n int := 0;
begin
  for r in select rolname from pg_roles
           where rolname in ('postgres','supabase_admin','supabase_storage_admin')
  loop
    begin
      execute format(
        'alter default privileges for role %I in schema public revoke all on tables from anon, authenticated',
        r.rolname);
      execute format(
        'alter default privileges for role %I in schema public revoke all on sequences from anon, authenticated',
        r.rolname);
      n := n + 1;
    exception when others then
      raise notice '  (مش قادر أعدّل الافتراضي لـ% — %)', r.rolname, left(sqlerrm, 60);
    end;
  end loop;
  raise notice '═══ الصلاحيات الافتراضية اتظبطت لـ% دور ═══', n;
end $d$;

COMMIT;

-- ── التحقق: الفرق المفروض يبقى صفر ──────────────────────────────────
with n_cloud as (
  select kind, obj, regexp_replace(regexp_replace(replace(ddl,'public.',''),'\s+',' ','g'),';\s*$','') d
  from cloudsrc.v_migration_ddl where kind in ('grant','fn_acl')
), n_srv as (
  select kind, obj, regexp_replace(regexp_replace(replace(ddl,'public.',''),'\s+',' ','g'),';\s*$','') d
  from public.v_migration_ddl where kind in ('grant','fn_acl')
)
select c.kind as "النوع", count(*) as "لسه منحرف"
from n_cloud c
where not exists (select 1 from n_srv s where s.kind = c.kind and s.d = c.d)
group by 1;

-- ولو حابب تشوف الزيادة اللي اتشالت: الجداول اللي كان عليها صلاحيات
-- أوسع بقت مطابقة — والزيادة دي كانت DELETE/INSERT/TRUNCATE في الغالب.
