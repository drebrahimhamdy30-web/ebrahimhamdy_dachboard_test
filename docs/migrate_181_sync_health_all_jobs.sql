/* ═══════════════════════════════════════════════════════════════════
   تنبيه المزامنة يغطّي كل المهام مش المخزون بس
   ═══════════════════════════════════════════════════════════════════
   ── ليه ──────────────────────────────────────────────────────────
   `get_sync_health` كانت بتفحص جداول مكتوبة بالاسم: مخزون الفروع
   و`customers`. فمزامنات الصلاحيات وتعديلات المخزون والمشتريات
   وأحجام العبوات كانت **برّه التغطية بالكامل**.

   والنتيجة اتشافت فعلًا: مزامنة الصلاحيات وقفت يومين بـ403 بعد
   `migrate_165` (تريجر السجل كان SECURITY INVOKER)، والخطأ كان
   متسجّل في `sync_runs` بس مفيش شاشة بتقوله. اتكشفت بالصدفة.

   ── المبدأ: القائمة تيجي من المحرّك مش من الكود ──────────────────
   الفحص بقى بيلفّ على `sync_jobs` المفعّلة و`sync_branch_state`،
   فأي مهمة جديدة تتغطّى **من غير ما حد يفتكر يضيفها هنا**. ده
   الفرق بين حارس بيتحدّث لوحده وحارس بينسى. راجع
   [[exists-by-name-not-state]].

   ── متى تُعتبر متأخرة ───────────────────────────────────────────
     السماح = أكبر من (دورة × ١.٥ + ٣٠ دقيقة) و٤٥ دقيقة
   يعني مهمة كل ساعة تتحوّش بعد ساعتين، واليومية بعد ٣٦ ساعة،
   واللي كل دقيقة بعد نص ساعة. ودورة ونص بتستوعب تأخير دورة واحدة
   من غير إنذار كاذب.

   و**آخر جولة لو فاشلة تتحوّش فورًا** مهما كان آخر نجاح قريب —
   دي اللي كانت هتمسك عطل الـ403 في أول ساعة بدل يومين.

   ⚠️ مفردات المحرّك: `sync_runs.status` فيها **ok / error** ودي
      مصدر الفشل. أما `sync_branch_state.last_status` ففيها
      **ok / empty**، و'empty' معناها «اشتغلت وما لقتش جديد» =
      نجاح. أول نسخة اعتبرتها فشل فطلّعت إنذار كاذب لأربع مهام
      سليمة. الاسم مش بيقول الحالة — راجع [[exists-by-name-not-state]].

   ⚠️ النتيجة بتتضاف لمصفوفة `feeds` الموجودة أصلًا، فـ`session.js`
      **ما بيتغيّرش** ولا محتاجين نرفع رقم إصدارها في ٤٠ شاشة.
      سبب الفشل بيتكتب في اسم البند نفسه عشان الرسالة تفضل مفهومة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_sync_health(p_hours int default 6)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
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
  v_gaps    jsonb := '[]'::jsonb;
begin
  if p_hours is null or p_hours <= 0 then p_hours := 6; end if;

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

  for f in
    select * from (values
      ('customers', 'أرصدة العملاء')
    ) as t(tbl_name, label)
  loop
    if to_regclass('public.' || quote_ident(f.tbl_name)) is null then
      continue;
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

  /* ── مهام المزامنة: القائمة من المحرّك نفسه ─────────────────── */
  for f in
    /* ⚠️ الفشل بيتقرا من `sync_runs` مش من `last_status`:
       `sync_branch_state.last_status` بياخد 'ok' أو **'empty'**،
       و'empty' معناها «اشتغلت وما لقتش جديد» — يعني نجاح. أول نسخة
       كانت بتعتبرها فشل فطلّعت إنذار كاذب لأربع مهام سليمة. */
    with last_run as (
      select distinct on (job_id, coalesce(branch,''))
             job_id, branch, status
        from public.sync_runs
       order by job_id, coalesce(branch,''), id desc
    ),
    st as (
      select s.job_id,
             min(s.last_sync_at)                                  as oldest_at,
             count(*)                                             as n_branches,
             count(*) filter (where lr.status = 'error')          as n_failed,
             count(*) filter (where s.last_sync_at is null)       as n_never,
             string_agg(coalesce(b.name, s.branch), '، ' order by s.branch)
               filter (where lr.status = 'error')                 as failed_names
        from public.sync_branch_state s
        left join public.branches b on b.code = s.branch
        left join last_run lr on lr.job_id = s.job_id
                             and coalesce(lr.branch,'') = coalesce(s.branch,'')
       where s.enabled
       group by s.job_id
    )
    select j.id, j.name, j.interval_minutes, st.oldest_at, st.n_branches,
           st.n_failed, st.n_never, st.failed_names,
           /* السماح: دورة ونص + نصف ساعة، وبحدّ أدنى ٤٥ دقيقة */
           greatest(coalesce(j.interval_minutes, 60) * 1.5 + 30, 45) as allow_min
      from public.sync_jobs j
      join st on st.job_id = j.id
     where j.enabled
     order by j.sort_order nulls last, j.id
  loop
    /* ⚠️ دقيقة واحدة فرق بين «بطيئة» و«واقفة»: آخر جولة فاشلة
       تتحوّش فورًا مهما كان آخر نجاح قريب — دي اللي كانت هتمسك
       عطل الـ403 في أول ساعة. */
    is_stale := (f.n_failed > 0)
             or (f.n_never > 0)
             or (f.oldest_at is null)
             or (extract(epoch from (now() - f.oldest_at)) / 60.0 > f.allow_min);

    if not is_stale then continue; end if;
    stale_n := stale_n + 1;

    feeds := feeds || jsonb_build_object(
      'key',  'sync:' || f.id,
      'name', 'مزامنة ' || f.name
              || case when f.n_failed > 0
                      then ' — آخر محاولة فشلت' ||
                           case when f.n_failed < f.n_branches
                                then ' (' || coalesce(f.failed_names, '') || ')' else '' end
                      when f.n_never > 0 then ' — لم تبدأ بعد'
                      else '' end,
      'rows', f.n_branches,
      'last_at', f.oldest_at,
      'age_hours', case when f.oldest_at is null then null
                   else round((extract(epoch from (now() - f.oldest_at)) / 3600.0)::numeric, 1) end,
      'stale', true,
      'reason', case when f.oldest_at is null then 'no_timestamp' else 'stale' end,
      'interval_minutes', f.interval_minutes);
  end loop;

  /* ⚠️ فجوات المبيعات دالة اختيارية: مش موجودة على السيرفر الذاتي،
     وكانت بتوقّع `get_sync_health` **كلها** هناك — يعني تنبيه
     التأخّر ماكانش شغّال على التست من أساسه والخطأ بيتبلع في
     console.warn. الفحص الناقص ما يصحّش يلغي الفحص كله. */
  if to_regprocedure('public.get_sales_gaps(int,int)') is not null then
    begin
      execute 'select coalesce(public.get_sales_gaps(21, 20) -> ''gaps'', ''[]''::jsonb)'
        into v_gaps;
    exception when others then v_gaps := '[]'::jsonb;
    end;
  end if;

  return jsonb_build_object(
    'checked_at',      now(),
    'threshold_hours', p_hours,
    'stale_count',     stale_n,
    'branches',        items,
    'feeds',           feeds,
    'sales_gaps',      v_gaps);
end$fn$;

notify pgrst, 'reload schema';
