-- ═══════════════════════════════════════════════════════════════════
--  حارس انهيار مخزون فرع + تنبيه يقول «فاضي» مش «متأخر»
-- ═══════════════════════════════════════════════════════════════════
--  🛑 حادثة 2026-11-09: `stock_bishr` اتبنى **فاضي** (صفر صف) واتنشر،
--  و`refresh_stock_flat()` أعاد بناء `stock_flat` منه — فرصيد سيدى بشر
--  بقى **صفر في كل الـ29 ألف صنف** وفي كل شاشة. المشتريات تفتكر الفرع
--  فاضي وتطلب كل حاجة، والتحويلات تقترح تحويل ليه، والحد الأدنى
--  والفائض غلط. والفرع كان سليم تمامًا (مزامنة الصلاحيات سحبت 11,399
--  صف في نفس اليوم) — المشكلة كانت في مسار المخزون وحده.
--
--  ليه عدّت: فيه مسارين مخزون. المسار المقسّم
--  (`commit_branch_stock`) **فيه حارس** بيرفض المرحلة الفاضية
--  (`empty_stage_refused`) — لكن اللي الشاشات بتقرا منه هو
--  `stock_<فرع>` → `stock_flat`، وده **مالوش أي حارس**.
--  وسجل `stock_flat_compare_log` كان بيقول «كل الفروق صفر» لأنه
--  بيقارن الجدول بنسخته الظل — مش بيسأل «هل فرع اتصفّر؟».
--
--  (١) حارس في `refresh_stock_flat`: لو فرع كان عنده صفوف وانهار
--      (فاضي أو أقل من نص اللي قبله) → **ماننشرش**، نسيب البيانات
--      القديمة مكانها ونكتب سبب الرفض في سجل المقارنة.
--      بيانات امبارح الصح أحسن من صفر النهاردة الغلط.
--  (٢) `get_sync_health`: جدول فرع فيه صفر صف يتقال عنه **فاضي**
--      مش «وقت التحديث غير مسجّل» — ده بيغيّر رد الفعل.
-- ═══════════════════════════════════════════════════════════════════

-- ── (١) الحارس جوّه إعادة البناء ────────────────────────────────────
do $$
declare
  src  text := pg_get_functiondef('public.refresh_stock_flat()'::regprocedure);
  nsrc text;
  anchor text := E'  if prev is not null and cur is not distinct from prev then return; end if;\n\n  truncate public.stock_flat;';
  guard  text :=
       E'  if prev is not null and cur is not distinct from prev then return; end if;\n\n'
    || E'  /* حارس الانهيار: فرع كان عنده صفوف وبقى فاضي (أو أقل من\n'
    || E'     نصّه) معناه مزامنة وقعت في النص، مش إن الفرع فضي بضاعته.\n'
    || E'     مانكملش النشر — القديم الصح أحسن من صفر غلط. السقف 100\n'
    || E'     صف عشان فرع جديد لسه بيتعبّى مايتحبسش. */\n'
    || E'  declare\n'
    || E'    n_m int; n_s int; n_b int; n_f int;\n'
    || E'    p_m int; p_s int; p_b int; p_f int;\n'
    || E'    bad text := null;\n'
    || E'  begin\n'
    || E'    select count(*) into n_m from stock_mamora;\n'
    || E'    select count(*) into n_s from stock_san;\n'
    || E'    select count(*) into n_b from stock_bishr;\n'
    || E'    select count(*) into n_f from stock_seyouf;\n'
    || E'    select count(*) filter (where m_h), count(*) filter (where s_h),\n'
    || E'           count(*) filter (where b_h), count(*) filter (where f_h)\n'
    || E'      into p_m, p_s, p_b, p_f from public.stock_flat;\n'
    || E'    if p_m > 100 and n_m < p_m / 2 then bad := ''mamora''; end if;\n'
    || E'    if p_s > 100 and n_s < p_s / 2 then bad := coalesce(bad||'','','''') || ''san''; end if;\n'
    || E'    if p_b > 100 and n_b < p_b / 2 then bad := coalesce(bad||'','','''') || ''bishr''; end if;\n'
    || E'    if p_f > 100 and n_f < p_f / 2 then bad := coalesce(bad||'','','''') || ''seyouf''; end if;\n'
    || E'    if bad is not null then\n'
    || E'      insert into public.stock_flat_compare_log(result) values (jsonb_build_object(\n'
    || E'        ''refused'', true, ''branches'', bad,\n'
    || E'        ''now'',  jsonb_build_object(''m'',n_m,''s'',n_s,''b'',n_b,''f'',n_f),\n'
    || E'        ''prev'', jsonb_build_object(''m'',p_m,''s'',p_s,''b'',p_b,''f'',p_f)));\n'
    || E'      raise warning ''stock_flat refresh refused: branch collapsed (%)'', bad;\n'
    || E'      return;\n'
    || E'    end if;\n'
    || E'  end;\n\n'
    || E'  truncate public.stock_flat;';
begin
  if position('حارس الانهيار' in src) > 0 then
    raise notice 'الحارس متحقون قبل كده';
    return;
  end if;
  if position(anchor in src) = 0 then
    raise exception 'مالقيتش نقطة الحقن في refresh_stock_flat — راجعها بإيدك';
  end if;
  nsrc := replace(src, anchor, guard);
  if nsrc = src then raise exception 'الاستبدال ماغيّرش حاجة'; end if;
  execute nsrc;
end $$;

-- ── (٢) التنبيه يقول «فاضي» ────────────────────────────────────────
do $$
declare
  src  text := pg_get_functiondef('public.get_sync_health(integer)'::regprocedure);
  nsrc text;
  anchor text :=
       E'    is_stale := (last_at is null) or (now() - last_at > (p_hours * interval ''1 hour''));\n'
    || E'    if is_stale then stale_n := stale_n + 1; end if;\n'
    || E'    items := items || jsonb_build_object(';
  guard text :=
       E'    /* جدول فرع فيه صفر صف = البيانات اتمسحت، مش اتأخرت.\n'
    || E'       الفرق مهم: «متأخر» يستنى، و«فاضي» يتصرف حالًا. */\n'
    || E'    is_stale := (n = 0) or (last_at is null)\n'
    || E'                or (now() - last_at > (p_hours * interval ''1 hour''));\n'
    || E'    if is_stale then stale_n := stale_n + 1; end if;\n'
    || E'    items := items || jsonb_build_object(';
begin
  if position('جدول فرع فيه صفر صف' in src) > 0 then
    raise notice 'متحقون قبل كده';
    return;
  end if;
  if position(anchor in src) = 0 then
    raise exception 'مالقيتش نقطة الحقن في get_sync_health';
  end if;
  nsrc := replace(src, anchor, guard);
  -- وسبب الحالة الفاضية يتقال باسمه
  nsrc := replace(nsrc,
    E'      ''reason'', case when last_at is null then ''no_timestamp''\n'
    || E'                     when is_stale        then ''stale'' else ''ok'' end);\n'
    || E'  end loop;\n\n  for f in select * from (values (''customers''',
    E'      ''reason'', case when n = 0            then ''empty''\n'
    || E'                     when last_at is null then ''no_timestamp''\n'
    || E'                     when is_stale        then ''stale'' else ''ok'' end);\n'
    || E'  end loop;\n\n  for f in select * from (values (''customers''');
  if nsrc = src then raise exception 'الاستبدال ماغيّرش حاجة'; end if;
  execute nsrc;
end $$;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_sync_health';
  if v_n <> 1 then raise exception 'فيه % نسخة من get_sync_health', v_n; end if;
end $$;

notify pgrst, 'reload schema';
