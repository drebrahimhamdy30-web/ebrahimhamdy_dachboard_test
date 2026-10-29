-- migrate_162_sync_health_feeds.sql
-- توسيع get_sync_health() ليغطي تغذيات بيانات مش بس جداول المخزون.
--
-- ليه: 2026-10-21 → 10-29 وقفت مزامنة أرصدة العملاء ٨ أيام وماحدّش حس —
-- نفس نوع العطل الصامت بتاع مخزون سان بالظبط: الشاشة بتعرض 150 بثقة
-- والحقيقة 4,500. اتكشفت بالصدفة لما المالك بصّ على عميل.
-- راجع docs/migrate_161_sync_health.sql و memory n8n-supabase-service-key-env.
--
-- الجديد: مفتاح 'feeds' في الناتج، أول عنصر فيه «أرصدة العملاء».
-- 'branches' زي ما هو (الشاشات القديمة اللي بتقراه ماتتأثرش).

create or replace function public.get_sync_health(p_hours numeric default 6)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r         record;
  f         record;
  tbl       text;
  last_at   timestamptz;
  n         bigint;
  is_stale  boolean;
  items     jsonb := '[]'::jsonb;
  feeds     jsonb := '[]'::jsonb;
  stale_n   int   := 0;
begin
  if p_hours is null or p_hours <= 0 then p_hours := 6; end if;

  -- ① جداول المخزون، فرع فرع
  for r in
    select code, name from public.branches
     where is_active and coalesce(code,'') <> ''
     order by sort_order nulls last, name
  loop
    tbl := 'stock_' || r.code;

    if to_regclass('public.' || quote_ident(tbl)) is null then
      items := items || jsonb_build_object(
        'code', r.code, 'name', r.name, 'rows', 0,
        'last_at', null, 'age_hours', null,
        'stale', true, 'reason', 'no_table');
      stale_n := stale_n + 1;
      continue;
    end if;

    execute format('select count(*), max(updated_at) from public.%I', tbl)
       into n, last_at;

    is_stale := (last_at is null) or (now() - last_at > (p_hours * interval '1 hour'));
    if is_stale then stale_n := stale_n + 1; end if;

    items := items || jsonb_build_object(
      'code', r.code, 'name', r.name, 'rows', n, 'last_at', last_at,
      'age_hours', case when last_at is null then null
                   else round((extract(epoch from (now() - last_at)) / 3600.0)::numeric, 1) end,
      'stale', is_stale,
      'reason', case when last_at is null then 'no_timestamp'
                     when is_stale        then 'stale' else 'ok' end);
  end loop;

  -- ② تغذيات تانية. لإضافة واحدة جديدة: سطر في القائمة دي وبس —
  --    بشرط إن الجدول فيه updated_at بيتبصم مع كل كتابة.
  for f in
    select * from (values
      ('customers', 'أرصدة العملاء')
    ) as t(tbl_name, label)
  loop
    if to_regclass('public.' || quote_ident(f.tbl_name)) is null then
      continue;   -- مش موجود على القاعدة دي — نسكت بدل ما ندّي إنذار كاذب
    end if;

    execute format('select count(*), max(updated_at) from public.%I', f.tbl_name)
       into n, last_at;

    is_stale := (last_at is null) or (now() - last_at > (p_hours * interval '1 hour'));
    if is_stale then stale_n := stale_n + 1; end if;

    feeds := feeds || jsonb_build_object(
      'key', f.tbl_name, 'name', f.label, 'rows', n, 'last_at', last_at,
      'age_hours', case when last_at is null then null
                   else round((extract(epoch from (now() - last_at)) / 3600.0)::numeric, 1) end,
      'stale', is_stale,
      'reason', case when last_at is null then 'no_timestamp'
                     when is_stale        then 'stale' else 'ok' end);
  end loop;

  return jsonb_build_object(
    'checked_at',      now(),
    'threshold_hours', p_hours,
    'stale_count',     stale_n,
    'branches',        items,
    'feeds',           feeds);
end
$fn$;

revoke all on function public.get_sync_health(numeric) from public;
revoke all on function public.get_sync_health(numeric) from anon;
grant execute on function public.get_sync_health(numeric) to authenticated, service_role;

notify pgrst, 'reload schema';
