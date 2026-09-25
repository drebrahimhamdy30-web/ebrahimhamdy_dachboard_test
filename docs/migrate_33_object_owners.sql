-- ═══════════════════════════════════════════════════════════════════
--  ملكية الكائنات على السيرفر = زي السحابة (postgres)
-- ═══════════════════════════════════════════════════════════════════
--  اتكشفت 2026-09-25 وإحنا بنحضّر تحويل n8n.
--
--  السحابة: ١٤٩ جدول، **كلهم** postgres. صفر استثناء.
--  السيرفر: ١٣ جدول مملوكين لـsupabase_admin — كل جدول اتعمل بملف
--           ترحيل، لأن الترحيل بيتنفّذ بـsupabase_admin.
--
--  ═══ ليه ده مش تفصيلة شكلية ═══
--
--  ١) stock_seyouf — ورك فلو «stock seuof» في n8n بيعمل Swap Tables،
--     يعني ALTER TABLE ... RENAME. والـrename في بوستجرس محتاج
--     **ملكية** الجدول، مش إذن كتابة. يوم التحويل لما n8n يتصل
--     بمستخدم postgres هيقع بـ«must be owner of table» — ورسالة
--     زي دي بتوديك تدوّر في فرع السيوف، مش في التحويل.
--
--  ٢) الدوال SECURITY DEFINER بتشتغل بصلاحيات **مالكها**. دالة
--     مملوكة لسوبر يوزر بتشتغل بصلاحيات أعلى من نظيرتها على
--     السحابة. ده مابيكسرش حاجة — بيوسّع ثقب بهدوء، وهو أسوأ،
--     لأن مفيش أي إشارة إنه حصل.
--
--  ⚠️ حارس الانحراف ماكانش هيمسكها: بيقارن **تعريفات** الكائنات
--     مش ملّاكها. ده اتضاف للحارس في نفس اليوم.
--
--  ═══ آمن ═══
--  تغيير المالك مابيلمسش بيانات ولا صلاحيات (GRANT) ولا سياسات
--  (RLS). وآمن يتعاد تشغيله: بيعدّي على اللي متظبّط خلاص.
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres -f - < /root/phalix-repo/docs/migrate_33_object_owners.sql
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ── قبل ───────────────────────────────────────────────────────────
select 'قبل' as المرحلة, 'جداول'  as النوع, count(*) as مش_postgres from pg_tables    where schemaname='public' and tableowner    <> 'postgres'
union all select 'قبل','views',    count(*) from pg_views     where schemaname='public' and viewowner     <> 'postgres'
union all select 'قبل','matviews', count(*) from pg_matviews  where schemaname='public' and matviewowner  <> 'postgres'
union all select 'قبل','سيكوينسات',count(*) from pg_sequences where schemaname='public' and sequenceowner <> 'postgres'
union all select 'قبل','دوال',     count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and pg_get_userbyid(p.proowner) <> 'postgres'
            and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e');

-- ── التصليح ───────────────────────────────────────────────────────
do $mig$
declare
  r record;
  nt int := 0; nv int := 0; nm int := 0; ns int := 0; nf int := 0;
begin
  -- الجداول. ملحوظة: تغيير مالك الجدول بيجرّ معاه الفهارس
  -- والسيكوينسات المملوكة لأعمدته، فبنعملها الأول.
  for r in select tablename from pg_tables
           where schemaname = 'public' and tableowner <> 'postgres'
  loop
    execute format('alter table public.%I owner to postgres', r.tablename);
    nt := nt + 1;
  end loop;

  for r in select viewname from pg_views
           where schemaname = 'public' and viewowner <> 'postgres'
  loop
    execute format('alter view public.%I owner to postgres', r.viewname);
    nv := nv + 1;
  end loop;

  for r in select matviewname from pg_matviews
           where schemaname = 'public' and matviewowner <> 'postgres'
  loop
    execute format('alter materialized view public.%I owner to postgres', r.matviewname);
    nm := nm + 1;
  end loop;

  -- السيكوينسات اللي فضلت (مش تابعة لعمود في جدول)
  for r in select sequencename from pg_sequences
           where schemaname = 'public' and sequenceowner <> 'postgres'
  loop
    execute format('alter sequence public.%I owner to postgres', r.sequencename);
    ns := ns + 1;
  end loop;

  -- الدوال — من غير اللي تابعة لإضافة (extension)، دي ملكيتها
  -- بتاعة الإضافة ومش بتاعتنا.
  for r in select p.oid::regprocedure as sig
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and pg_get_userbyid(p.proowner) <> 'postgres'
             and not exists (select 1 from pg_depend d
                             where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s owner to postgres', r.sig);
    nf := nf + 1;
  end loop;

  raise notice 'اتغيّر: % جدول · % view · % matview · % سيكوينس · % دالة', nt, nv, nm, ns, nf;
end $mig$;

-- ── بعد — لازم كله أصفار ──────────────────────────────────────────
select 'بعد' as المرحلة, 'جداول'  as النوع, count(*) as مش_postgres from pg_tables    where schemaname='public' and tableowner    <> 'postgres'
union all select 'بعد','views',    count(*) from pg_views     where schemaname='public' and viewowner     <> 'postgres'
union all select 'بعد','matviews', count(*) from pg_matviews  where schemaname='public' and matviewowner  <> 'postgres'
union all select 'بعد','سيكوينسات',count(*) from pg_sequences where schemaname='public' and sequenceowner <> 'postgres'
union all select 'بعد','دوال',     count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and pg_get_userbyid(p.proowner) <> 'postgres'
            and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e');

-- ── الدوال SECURITY DEFINER — للعلم، لازم كلها postgres دلوقتي ────
select count(*) as "دوال SECURITY DEFINER",
       count(*) filter (where pg_get_userbyid(p.proowner) <> 'postgres') as "مالكها مش postgres"
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosecdef;
