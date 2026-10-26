-- migrate_161_sync_health.sql
-- دالة فحص تأخّر مزامنة المخزون + تنبيه في كل الشاشات.
--
-- ليه: 2026-10-26 وقفت مزامنة سان ستيفانو ٢٧ ساعة وماحدّش حس — كل عقد
-- n8n كانت خضرا (التنفيذ كان بيتلغي عند مهلة ٦ دقايق، و«Canceled»
-- مابيتعدّش خطأ)، والشاشات كانت بتعرض رصيد بايت كإنه سليم.
-- التفاصيل في docs/n8n_insert_staging_bulk.md.
--
-- بترجّع jsonb (صف واحد) فمش متأثرة بسقف الألف صف.
-- SECURITY DEFINER لأن جداول المخزون مقفولة على authenticated.
-- بتقرا الفروع من branches.code فأي فرع جديد يتغطّى لوحده —
-- ممنوع تثبيت أسماء الفروع هنا.

drop function if exists public.get_sync_health(int);

create or replace function public.get_sync_health(p_hours numeric default 6)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r         record;
  tbl       text;
  last_at   timestamptz;
  n         bigint;
  is_stale  boolean;
  items     jsonb := '[]'::jsonb;
  stale_n   int   := 0;
begin
  if p_hours is null or p_hours <= 0 then p_hours := 6; end if;

  for r in
    select code, name from public.branches
     where is_active and coalesce(code,'') <> ''
     order by sort_order nulls last, name
  loop
    tbl := 'stock_' || r.code;

    -- الجدول ممكن مايكونش موجود (فرع جديد لسه ماتزامنش ولا مرة).
    -- ولاحظ: جداول المخزون بتتبدّل بـrename/drop كل مزامنة، عشان كده
    -- الاستعلام ديناميكي — الخطة المتخزّنة بتبوظ مع إعادة التسمية.
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

  return jsonb_build_object(
    'checked_at',      now(),
    'threshold_hours', p_hours,
    'stale_count',     stale_n,
    'branches',        items);
end
$fn$;

-- ⚠️ PUBLIC بياخد EXECUTE افتراضيًا على أي دالة جديدة — لازم يتسحب،
--    وإلا مفتاح anon يقدر يناديها. راجع ذاكرة anon-key-lockdown.
revoke all on function public.get_sync_health(numeric) from public;
revoke all on function public.get_sync_health(numeric) from anon;
grant execute on function public.get_sync_health(numeric) to authenticated, service_role;

notify pgrst, 'reload schema';
