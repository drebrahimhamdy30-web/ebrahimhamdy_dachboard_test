-- ═══════════════════════════════════════════════════════════════════
--  إصلاح تنبيه تأخّر المزامنة + إضافة مديونيات العملاء له
-- ═══════════════════════════════════════════════════════════════════
--  🛑 التنبيه كان **ميت في كل الشاشات** وبالصمت:
--  `get_sync_health` كان ليها نسختان — القديمة (p_hours numeric)
--  والكاملة اللي جابها migrate_181 (p_hours integer). PostgREST
--  مابيعرفش يختار بينهم فبيرد **300 Multiple Choices**، وsession.js
--  بيرمي على أي رد مش ناجح، فالتنبيه مابيظهرش خالص.
--  السبب: `create or replace function` بنوع بارامتر مختلف بيعمل
--  نسخة **جديدة** مش بيستبدل القديمة — نفس فخ rating_comments.
--
--  وبنضيف مزامنة مديونيات العملاء للتنبيه: السكربت بيشتغل بمهمة
--  مجدولة برّه محرّك sync_jobs، وماكانش فيه حاجة تقول لو وقف.
--  سقفها 30 ساعة مش p_hours لأنها يومية — 6 ساعات كانت هتولّع
--  تنبيه كل يوم بعد الظهر وهي سليمة.
--
--  ⚠️ ماتسجّلش المزامنة دي في sync_jobs: المحرّك بيعدّي على المهام
--     المتفعّلة ولو ملقاش لها صفوف في sync_branch_state بيختمها
--     last_status='ok' من غير ما ينفّذ حاجة — أخضر كاذب.
--
--  التعديل **جراحي**: بناخد تعريف الدالة الحالي ونحقن فيه الكتلة
--  الجديدة، بدل ما نعيد كتابة 150 سطر ونخاطر باختلاف صامت عن
--  النسخة الشغّالة.
-- ═══════════════════════════════════════════════════════════════════

-- ١) النسخة القديمة تتشال — بشرط إن الكاملة موجودة
do $$
begin
  if to_regprocedure('public.get_sync_health(integer)') is null then
    raise exception 'النسخة الكاملة (integer) مش موجودة — مش هنحذف القديمة';
  end if;
  drop function if exists public.get_sync_health(numeric);
end $$;

-- ٢) حقن فحص مديونيات العملاء جوّه الدالة الكاملة
do $$
declare
  src  text := pg_get_functiondef('public.get_sync_health(integer)'::regprocedure);
  nsrc text;
  anchor text :=
    E'  end loop;\n\n  for f in\n    with last_run as (';
  block text :=
    E'  end loop;\n\n'
    || E'  /* مديونيات العملاء — مزامنة يومية بمهمة مجدولة على الماستر،\n'
    || E'     فالسقف 30 ساعة (يوم + هامش) مش p_hours. */\n'
    || E'  if to_regclass(''public.customer_credits'') is not null then\n'
    || E'    select count(*), max(synced_at) into n, last_at from public.customer_credits;\n'
    || E'    is_stale := (last_at is null) or (now() - last_at > interval ''30 hours'');\n'
    || E'    if is_stale then stale_n := stale_n + 1; end if;\n'
    || E'    feeds := feeds || jsonb_build_object(\n'
    || E'      ''key'', ''customer_credits'', ''name'', ''مزامنة مديونيات العملاء'',\n'
    || E'      ''rows'', n, ''last_at'', last_at,\n'
    || E'      ''age_hours'', case when last_at is null then null\n'
    || E'                   else round((extract(epoch from (now() - last_at)) / 3600.0)::numeric, 1) end,\n'
    || E'      ''stale'', is_stale,\n'
    || E'      ''reason'', case when last_at is null then ''no_timestamp''\n'
    || E'                     when is_stale        then ''stale'' else ''ok'' end,\n'
    || E'      ''interval_minutes'', 1440);\n'
    || E'  end if;\n\n'
    || E'  for f in\n    with last_run as (';
begin
  if position('customer_credits' in src) > 0 then
    raise notice 'الفحص متحقون قبل كده — مفيش تغيير';
    return;
  end if;
  if position(anchor in src) = 0 then
    raise exception 'مالقيتش نقطة الحقن — الدالة اتغيّرت، راجعها بإيدك';
  end if;
  nsrc := replace(src, anchor, block);
  if nsrc = src then
    raise exception 'الاستبدال ماغيّرش حاجة';
  end if;
  execute nsrc;
end $$;

-- ٣) لازم تفضل نسخة واحدة بس، وإلا النداء هيفضل غامض
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_sync_health';
  if v_n <> 1 then
    raise exception 'لسه فيه % نسخة من get_sync_health — النداء هيفضل غامض', v_n;
  end if;
end $$;

revoke all on function public.get_sync_health(integer) from public;
grant execute on function public.get_sync_health(integer) to authenticated, service_role;

notify pgrst, 'reload schema';
