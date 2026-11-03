-- ═══════════════════════════════════════════════════════════════════
--  فحص الصحة: مهمة مزامنة متفعّلة بلا فروع = «غير مجهّزة» مش «تمام»
-- ═══════════════════════════════════════════════════════════════════
--  🛑 الحادثة (2026-11-03): شبكتا الأمان `saved_contracts` و
--  `saved_sales` كانتا **متفعّلتين وبصفر فروع مجهّزة**. المحرّك بيعدّي
--  على المهمة، بيجيب فروعها من `sync_branch_state` فيلاقيها فاضية،
--  **مابينفّذش ولا خطوة**، وبعدين بيختم `last_status='ok'`. فضلت
--  تقول «تمام» كل ساعة من يوم ما اتبنت، وهي ماشتغلتش ولا مرة.
--
--  والفحص نفسه كان بيعمّيها: الاستعلام بيعمل
--  `sync_jobs j JOIN st ON st.job_id = j.id` و`st` مبنية من
--  `sync_branch_state` — فالمهمة اللي **مالهاش ولا صف** بتقع من
--  الـJOIN أصلًا وماتدخلش الفحص. يعني كل ما المهمة تبقى أهمَل،
--  كل ما الفحص يسكت عنها أكتر.
--
--  الإصلاح: قبل حلقة المهام، نعدّي على المهام المتفعّلة اللي مالهاش
--  ولا فرع مفعّل ونعلّمها متأخرة بسبب `not_configured`.
--
--  التعديل جراحي (pg_get_functiondef + حقن + حارس) زي migrate_191.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare
  src  text := pg_get_functiondef('public.get_sync_health(integer)'::regprocedure);
  nsrc text;
  anchor text := E'  for f in\n    with last_run as (';
  block  text :=
       E'  /* مهمة متفعّلة بلا فروع مجهّزة: المحرّك بيختمها «تمام» من\n'
    || E'     غير ما ينفّذ حاجة، والـJOIN تحت بيسقّطها لأن مالهاش صفوف\n'
    || E'     في sync_branch_state. لازم تتقال هنا صراحة. */\n'
    || E'  for f in\n'
    || E'    select j.id, j.name from public.sync_jobs j\n'
    || E'     where j.enabled\n'
    || E'       and not exists (select 1 from public.sync_branch_state s\n'
    || E'                        where s.job_id = j.id and s.enabled)\n'
    || E'     order by j.sort_order nulls last, j.id\n'
    || E'  loop\n'
    || E'    stale_n := stale_n + 1;\n'
    || E'    feeds := feeds || jsonb_build_object(\n'
    || E'      ''key'', ''sync:'' || f.id,\n'
    || E'      ''name'', ''مزامنة '' || f.name || '' — غير مجهّزة (مفيش فروع مفعّلة)'',\n'
    || E'      ''rows'', 0, ''last_at'', null, ''age_hours'', null,\n'
    || E'      ''stale'', true, ''reason'', ''not_configured'');\n'
    || E'  end loop;\n\n'
    || E'  for f in\n    with last_run as (';
begin
  if position('not_configured' in src) > 0 then
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

-- لازم تفضل نسخة واحدة بس
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_sync_health';
  if v_n <> 1 then
    raise exception 'فيه % نسخة من get_sync_health — النداء هيبقى غامض', v_n;
  end if;
end $$;

revoke all on function public.get_sync_health(integer) from public;
grant execute on function public.get_sync_health(integer) to authenticated, service_role;

notify pgrst, 'reload schema';
