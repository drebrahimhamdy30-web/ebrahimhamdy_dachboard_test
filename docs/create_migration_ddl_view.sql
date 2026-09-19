-- ═══════════════════════════════════════════════════════════════════
--  v_migration_ddl على السيرفر الذاتي — نسخة مطابقة لبتاعة السحابة
-- ═══════════════════════════════════════════════════════════════════
--  الـview ده بيولّد أوامر الإنشاء لكل حاجة في public من الكتالوج.
--  موجود على السحابة من أيام الترحيل، وبنعمله هنا كمان عشان نقدر
--  نقارن الجهتين **بنفس الصيغة بالظبط** كل يوم ونكتشف أي انحراف.
--
--  ⚠️ الفرق الوحيد عن نسخة السحابة: بيوحّد **الرابطين**.
--     نسخة السحابة بتستبدل رابط السحابة بـ__TARGET_URL__ بس. هنا
--     بنستبدل الاتنين (السحابة والسيرفر)، عشان دالة الفرق الوحيد
--     فيها إنها بتنده سيرفر مختلف ماتظهرش كانحراف كل يوم.
--
--  التشغيل مرة واحدة:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/create_migration_ddl_view.sql
-- ═══════════════════════════════════════════════════════════════════

create or replace view public.v_migration_ddl as
 SELECT 10 AS ord, 'extension'::text AS kind, e.extname AS obj,
    format('create extension if not exists %I;'::text, e.extname) AS ddl
   FROM pg_extension e
  WHERE e.extname <> 'plpgsql'::name
UNION ALL
 SELECT 20 AS ord, 'sequence'::text AS kind, c.relname AS obj,
    format('create sequence if not exists public.%I;'::text, c.relname) AS ddl
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'::name AND c.relkind = 'S'::"char"
UNION ALL
 SELECT 30 AS ord, 'table'::text AS kind, c.relname AS obj,
    format('create table if not exists public.%I (%s);'::text, c.relname,
      string_agg(format('%I %s%s%s'::text, a.attname, format_type(a.atttypid, a.atttypmod),
        CASE WHEN a.attidentity <> ''::"char" THEN format(' generated %s as identity'::text,
               CASE a.attidentity WHEN 'a'::"char" THEN 'always'::text ELSE 'by default'::text END)
             WHEN ad.adbin IS NOT NULL THEN ' default '::text || pg_get_expr(ad.adbin, ad.adrelid)
             ELSE ''::text END,
        CASE WHEN a.attnotnull THEN ' not null'::text ELSE ''::text END), ',
  '::text ORDER BY a.attnum)) AS ddl
   FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     LEFT JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
  WHERE n.nspname = 'public'::name AND c.relkind = 'r'::"char"
  GROUP BY c.relname
UNION ALL
 SELECT 40 AS ord, 'constraint'::text AS kind, con.conname AS obj,
    format('alter table public.%I add constraint %I %s;'::text, cl.relname, con.conname,
           pg_get_constraintdef(con.oid)) AS ddl
   FROM pg_constraint con
     JOIN pg_class cl ON cl.oid = con.conrelid
     JOIN pg_namespace n ON n.oid = cl.relnamespace
  WHERE n.nspname = 'public'::name AND (con.contype = ANY (ARRAY['p'::"char", 'u'::"char", 'c'::"char"]))
UNION ALL
 SELECT 50 AS ord, 'fk'::text AS kind, con.conname AS obj,
    format('alter table public.%I add constraint %I %s;'::text, cl.relname, con.conname,
           pg_get_constraintdef(con.oid)) AS ddl
   FROM pg_constraint con
     JOIN pg_class cl ON cl.oid = con.conrelid
     JOIN pg_namespace n ON n.oid = cl.relnamespace
  WHERE n.nspname = 'public'::name AND con.contype = 'f'::"char"
UNION ALL
 SELECT 60 AS ord, 'index'::text AS kind, i.indexname AS obj,
    i.indexdef || ';'::text AS ddl
   FROM pg_indexes i
  WHERE i.schemaname = 'public'::name
    AND NOT (EXISTS ( SELECT 1 FROM pg_constraint con
                      JOIN pg_class ic ON ic.oid = con.conindid
                     WHERE ic.relname = i.indexname))
UNION ALL
 SELECT 70 AS ord, 'function'::text AS kind, p.proname AS obj,
    replace(replace(pg_get_functiondef(p.oid),
            'https://rxtjoqulmgkkcohmgzgi.supabase.co'::text, '__TARGET_URL__'::text),
            'https://supabase.ebrahimhamdy.com'::text, '__TARGET_URL__'::text) || ';'::text AS ddl
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'::name AND (p.prokind = ANY (ARRAY['f'::"char", 'p'::"char"]))
UNION ALL
 SELECT 80 AS ord, 'view'::text AS kind, c.relname AS obj,
    format('create or replace view public.%I as %s'::text, c.relname,
      replace(replace(pg_get_viewdef(c.oid),
              'https://rxtjoqulmgkkcohmgzgi.supabase.co'::text, '__TARGET_URL__'::text),
              'https://supabase.ebrahimhamdy.com'::text, '__TARGET_URL__'::text)) AS ddl
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'::name AND c.relkind = 'v'::"char"
    AND c.relname !~~ 'v\_migration\_%'::text
UNION ALL
 SELECT 90 AS ord, 'trigger'::text AS kind, t.tgname AS obj,
    pg_get_triggerdef(t.oid) || ';'::text AS ddl
   FROM pg_trigger t
     JOIN pg_class cl ON cl.oid = t.tgrelid
     JOIN pg_namespace n ON n.oid = cl.relnamespace
  WHERE n.nspname = 'public'::name AND NOT t.tgisinternal
UNION ALL
 SELECT 100 AS ord, 'rls'::text AS kind, c.relname AS obj,
    format('alter table public.%I enable row level security;'::text, c.relname) AS ddl
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'::name AND c.relkind = 'r'::"char" AND c.relrowsecurity
UNION ALL
 SELECT 110 AS ord, 'policy'::text AS kind, p.policyname AS obj,
    format('create policy %I on public.%I as %s for %s to %s%s%s;'::text, p.policyname, p.tablename,
      CASE WHEN p.permissive = 'PERMISSIVE'::text THEN 'permissive'::text ELSE 'restrictive'::text END,
      p.cmd, array_to_string(p.roles, ', '::text),
      COALESCE((' using ('::text || p.qual) || ')'::text, ''::text),
      COALESCE((' with check ('::text || p.with_check) || ')'::text, ''::text)) AS ddl
   FROM pg_policies p
  WHERE p.schemaname = 'public'::name
UNION ALL
 SELECT 120 AS ord, 'grant'::text AS kind,
    (g.table_name::text || ':'::text) || g.grantee::text AS obj,
    format('grant %s on public.%I to %I;'::text,
           string_agg(DISTINCT g.privilege_type::text, ', '::text), g.table_name, g.grantee) AS ddl
   FROM information_schema.role_table_grants g
  WHERE g.table_schema::name = 'public'::name
    AND (g.grantee::name = ANY (ARRAY['anon'::name, 'authenticated'::name, 'service_role'::name]))
    AND g.table_name::name !~~ 'v\_migration\_%'::text
  GROUP BY g.table_name, g.grantee
UNION ALL
 SELECT 130 AS ord, 'fn_acl'::text AS kind, p.proname AS obj,
    format('revoke all on function public.%I(%s) from public, anon, authenticated; '::text,
           p.proname, pg_get_function_identity_arguments(p.oid)) ||
    format('grant execute on function public.%I(%s) to %s;'::text, p.proname,
           pg_get_function_identity_arguments(p.oid),
           array_to_string(ARRAY( SELECT r.r FROM unnest(ARRAY['anon'::text,'authenticated'::text,'service_role'::text]) r(r)
                                   WHERE has_function_privilege(r.r::name, p.oid, 'EXECUTE'::text)), ', '::text)) AS ddl
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'::name AND (p.prokind = ANY (ARRAY['f'::"char", 'p'::"char"]))
    AND array_length(ARRAY( SELECT r.r FROM unnest(ARRAY['anon'::text,'authenticated'::text,'service_role'::text]) r(r)
                             WHERE has_function_privilege(r.r::name, p.oid, 'EXECUTE'::text)), 1) > 0;

select count(*) as "أوامر DDL على السيرفر" from public.v_migration_ddl;
