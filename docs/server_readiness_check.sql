-- ═══════════════════════════════════════════════════════════════════
--  فحص جاهزية السيرفر — مقارنة بالسحابة
-- ═══════════════════════════════════════════════════════════════════
--  يتشغّل على supabase.ebrahimhamdy.com في SQL Editor.
--  بيقرا بس — مابيغيّرش أي حاجة.
--
--  الأرقام المتوقّعة مأخوذة من السحابة يوم 2026-09-15.
--  فرق بسيط في الدوال/التريجرات عادي (امتدادات مختلفة)؛
--  اللي يهم هو البنود اللي عليها ⛔.
--
--  ⚠️ «مهام cron» المتوقّع = 0 عن قصد. السيرفر لازم يفضل ساكن
--     لحد ما السحابة تتوقف — وإلا إشعارات مزدوجة للطيارين ومزامنة
--     مكرّرة على eplus. راجع docs/migrate_09_safety_isolation.sql
-- ═══════════════════════════════════════════════════════════════════

with a as (
  select 'جداول public' as البند, 121 as المتوقع,
         (select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as الفعلي, 'eq' as نوع
  union all select 'views', 7,
         (select count(*) from information_schema.views where table_schema='public'), 'eq'
  union all select 'دوال public', 214,
         (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'), 'gte'
  union all select 'تريجرات', 47,
         (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public'), 'gte'
  union all select 'سياسات RLS', 117,
         (select count(*) from pg_policy pol join pg_class c on c.oid=pol.polrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'), 'gte'
  union all select 'جداول RLS مفعّل', 114,
         (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and c.relrowsecurity), 'gte'
  union all select 'حسابات auth', 88,
         (select count(*) from auth.users), 'gte'
  union all select 'أسرار vault', 6,
         (select count(*) from vault.decrypted_secrets), 'gte'
  union all select 'buckets', 3,
         (select count(*) from storage.buckets), 'gte'
  union all select '⚠️ مهام cron (لازم صفر)', 0,
         (select count(*) from cron.job), 'eq'
)
select البند, المتوقع, الفعلي,
       case when نوع='eq'  and الفعلي = المتوقع then '✅'
            when نوع='gte' and الفعلي >= المتوقع then '✅'
            when الفعلي = 0 then '⛔ مفقود تمامًا'
            else '⚠️ ناقص ' || (المتوقع - الفعلي)::text end as الحالة
from a

union all select '───────────────', null, null, '───────────────'

-- كائنات بعينها ضفناها في الجلسات الأخيرة
union all select 'جدول integration_branch_stores', null, null,
  case when to_regclass('public.integration_branch_stores') is null then '⛔ ناقص — شغّل docs/integration_branch_stores.sql'
       else '✅ (' || (select count(*) from public.integration_branch_stores)::text || ' صف)' end
union all select 'حارس: منع تعيين طلب متسلّم', null, null,
  case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                    where n.nspname='public' and p.proname='manual_assign_order'
                      and p.prosrc like '%delivered%' and p.prosrc like '%completed%')
       then '✅' else '⛔ ناقص — docs/fix_no_reassign_delivered.sql' end
union all select 'حارس: قفل وقت التسليم', null, null,
  case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                    where n.nspname='public' and p.proname='trg_server_event_time'
                      and p.prosrc like '%NEW.delivered_at := OLD.delivered_at%')
       then '✅' else '⛔ ناقص — القسم 3 من نفس الملف' end
union all select 'دالة vault_secret()', null, null,
  case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                    where n.nspname='public' and p.proname='vault_secret')
       then '✅' else '⛔ ناقص — 6 دوال Edge بتقرا أسرارها منها' end
union all select 'anon مقفول على orders', null, null,
  case when exists (select 1 from information_schema.role_table_grants
                    where table_schema='public' and table_name='orders' and grantee='anon')
       then '⛔ anon لسه عنده صلاحية' else '✅' end;
