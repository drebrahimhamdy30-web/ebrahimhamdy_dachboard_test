-- ═══════════════════════════════════════════════════════════════════
--  فرق الدوال: السيرفر مقابل السحابة — مقارنة حية قاعدة بقاعدة
-- ═══════════════════════════════════════════════════════════════════
--  اتعمل 2026-09-25 بعد ما عدّاد بسيط كشف إن السحابة فيها ٢٤٢ دالة
--  والسيرفر ٢٣١ — **وحارس الانحراف اليومي قايل «صفر انحراف»**.
--
--  الحارس بيقارن نص أوامر DDL من `cloudsrc.v_migration_ddl`. الملف ده
--  بيقارن **كتالوج مقابل كتالوج** مباشرة عبر dblink على السيرفر
--  الأجنبي `cloud` الموجود أصلًا. فلو الاتنين اختلفوا، الفرق بينهم
--  نفسه بيقول لنا الحارس بيفوّت إيه.
--
--  🔒 مافيش أي كلمة سر هنا: dblink بياخد **اسم السيرفر الأجنبي**
--     ويستعمل user mapping الموجود. القيم مابتعدّيش على الشاشة.
--
--  بيقيس ٤ حاجات:
--    ١) العدد في الجهتين
--    ٢) ناقصة على السيرفر   ← دي اللي تكسر شاشة أو ورك فلو
--    ٣) زيادة على السيرفر   ← شغل محلي (الفورمات الطولي) أو بقايا
--    ٤) SECURITY DEFINER مختلف  ← موجودة في الجهتين بس بصلاحيات مختلفة.
--       دي أخطر نوع لأنها مابتكسرش حاجة — بتشتغل بصلاحية غلط بهدوء.
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres \
--      < /root/phalix-repo/docs/schema_diff_funcs_vs_prod.sql
-- ═══════════════════════════════════════════════════════════════════

\pset pager off

-- الدوال المحلية — من غير التابعة لإضافة (ملكيتها بتاعة الإضافة)
create temp view _local_fn as
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig,
       p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');

-- نفس الاستعلام بالظبط على السحابة
create temp view _cloud_fn as
select * from dblink('cloud', $q$
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig,
         p.prosecdef
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
$q$) as t(sig text, prosecdef boolean);

-- ── ١) العدد ──────────────────────────────────────────────────────
select 'السحابة' as الجهة, count(*) as الدوال,
       count(*) filter (where prosecdef) as security_definer from _cloud_fn
union all
select 'السيرفر', count(*), count(*) filter (where prosecdef) from _local_fn;

-- ── ٢) ناقصة على السيرفر ─────────────────────────────────────────
select '🔴 ناقصة على السيرفر' as الحالة, sig as الدالة
from (select sig from _cloud_fn except select sig from _local_fn) a
order by 2;

-- ── ٣) زيادة على السيرفر ─────────────────────────────────────────
-- متوقّع هنا: شغل الفورمات الطولي (branch_stock_* · shadow_tick)
-- ودوال المقارنة والهجرة. أي حاجة تانية تستاهل سؤال.
select '🟡 زيادة على السيرفر' as الحالة, sig as الدالة
from (select sig from _local_fn except select sig from _cloud_fn) b
order by 2;

-- ── ٤) موجودة في الجهتين بس SECURITY DEFINER مختلف ───────────────
-- دي أخطر حالة: الدالة شغّالة، والشاشة بتشتغل، والحارس مبسوط —
-- وهي بتشتغل بصلاحيات غير اللي المفروض.
select '🔑 SECURITY DEFINER مختلف' as الحالة, c.sig as الدالة,
       c.prosecdef as "السحابة", l.prosecdef as "السيرفر"
from _cloud_fn c join _local_fn l using (sig)
where c.prosecdef is distinct from l.prosecdef
order by 2;
