-- ═══════════════════════════════════════════════════════════════════
--  صحة المزامنة: حقول مفصولة بدل جملة مدموجة
-- ═══════════════════════════════════════════════════════════════════
--  كان اسم الفرع **مدفون جوّه النص**:
--    "مزامنة المشتريات — فشلت 166 محاولات متتالية (سيدى بشر)"
--  فالواجهة مش قادرة تجمّع، ومضطرة تصفّ عشر جمل لسبب واحد (نت فرع
--  فاصل). الشريط بقى ~600 حرف بيغطّي أول كل شاشة — وبيوصل للطيار
--  كمان، واللي الرسالة نفسها بتقوله «يُرجى إبلاغ الإدارة».
--
--  دلوقتى كل مهمة بترجّع كمان:
--    job · job_name · branches_failed[{code,name,fails,age_hours,class}]
--  و class بيفرّق:
--    unreachable → السيرفر مش موصول  (اتصل بالفرع)
--    job_error   → المهمة نفسها بايظة (تتصلّح في الكود)
--  الفرق بينهم كبير في رد الفعل، وكانوا بيطلعوا بنفس الشكل بالظبط.
--
--  ⚠️ class بيتحدد من **نص** رسالة الخطأ، ونصوص SQL Server ممكن
--     تتغيّر. فالمجهول بيتحسب job_error (الأعلى خطورة) — أحسن من
--     إننا نقول «الفرع واقع» ونسيب عطل حقيقي يعدّي.
--
--  ⚠️ name اتساب بالحرف زي ما كان: شاشات قديمة بتعرضه، والتغيير كان
--     هيكسرها في صمت. الحقول الجديدة **جنبه** مش بدله.
--
--  اتطبّق على السحابة 2026-11-16 واتجرّب على بيانات حقيقية:
--    10 مهام فاشلة لسيدى بشر → class=unreachable للعشرة،
--    والواجهة جمّعتهم في سطر واحد بدل عشرة.
--
--  الذاتي:
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres -f - \
--      < /root/phalix-repo/docs/migrate_218_sync_health_structured.sql
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_sync_health(p_hours integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      items := items || jsonb_build_object('code', r.code, 'name', r.name, 'rows', 0,
        'last_at', null, 'age_hours', null, 'stale', true, 'reason', 'no_table');
      stale_n := stale_n + 1;
      continue;
    end if;
    execute format('select count(*), max(updated_at) from public.%I', tbl) into n, last_at;
    /* جدول فرع فيه صفر صف = البيانات اتمسحت، مش اتأخرت.
       الفرق مهم: «متأخر» يستنى، و«فاضي» يتصرف حالًا. */
    is_stale := (n = 0) or (last_at is null)
                or (now() - last_at > (p_hours * interval '1 hour'));
    if is_stale then stale_n := stale_n + 1; end if;
    items := items || jsonb_build_object(
      'code', r.code, 'name', r.name, 'rows', n, 'last_at', last_at,
      'age_hours', case when last_at is null then null
                   else round((extract(epoch from (now() - last_at)) / 3600.0)::numeric, 1) end,
      'stale', is_stale,
      'reason', case when n = 0            then 'empty'
                     when last_at is null then 'no_timestamp'
                     when is_stale        then 'stale' else 'ok' end);
  end loop;

  for f in select * from (values ('customers', 'أرصدة العملاء')) as t(tbl_name, label)
  loop
    if to_regclass('public.' || quote_ident(f.tbl_name)) is null then continue; end if;
    execute format('select count(*), max(updated_at) from public.%I', f.tbl_name) into n, last_at;
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

  for f in
    with r3 as (
      select job_id, branch, status,
             row_number() over (partition by job_id, branch order by id desc) rn
        from public.sync_runs
       where ran_at > now() - interval '3 days'
    ),
    ok1 as (select job_id, branch, min(rn) rn_ok from r3 where status = 'ok' group by job_id, branch),
    tot as (select job_id, branch, max(rn) n from r3 group by job_id, branch),
    cons as (
      select t.job_id, t.branch, coalesce(o.rn_ok, t.n + 1) - 1 as consec_fail
        from tot t left join ok1 o on o.job_id = t.job_id and o.branch = t.branch
    ),
    /* آخر رسالة خطأ لكل (مهمة، فرع) — منها بنعرف نوع العطل */
    lasterr as (
      select distinct on (job_id, branch) job_id, branch, error
        from public.sync_runs
       where ran_at > now() - interval '3 days' and status <> 'ok'
       order by job_id, branch, id desc
    ),
    st as (
      select s.job_id,
             min(s.last_sync_at)                               as oldest_at,
             count(*)                                          as n_branches,
             count(*) filter (where s.last_sync_at is null)    as n_never,
             coalesce(max(c.consec_fail), 0)                   as max_consec,
             string_agg(coalesce(b.name, s.branch), '، ' order by s.branch)
               filter (where c.consec_fail >= 3)               as failed_names,
             count(*) filter (where c.consec_fail >= 3)        as n_failed,
             coalesce(jsonb_agg(jsonb_build_object(
               'code',  s.branch,
               'name',  coalesce(b.name, s.branch),
               'fails', c.consec_fail,
               'age_hours', case when s.last_sync_at is null then null
                            else round((extract(epoch from (now() - s.last_sync_at)) / 3600.0)::numeric, 1) end,
               'class', case
                 when e.error ~* '(network-related|no route to host|server was not found|not accessible|timeout expired|semaphore timeout|connection .*(closed|refused|reset))'
                   then 'unreachable'
                 else 'job_error'   -- المجهول يتحسب عطل، مش انقطاع
               end
             ) order by s.branch) filter (where c.consec_fail >= 3), '[]'::jsonb) as failed_json
        from public.sync_branch_state s
        left join public.branches b on b.code = s.branch
        left join cons    c on c.job_id = s.job_id and c.branch = s.branch
        left join lasterr e on e.job_id = s.job_id and e.branch = s.branch
       where s.enabled
       group by s.job_id
    )
    select j.id, j.name, j.interval_minutes, st.oldest_at, st.n_branches,
           st.n_failed, st.n_never, st.failed_names, st.max_consec, st.failed_json,
           greatest(coalesce(j.interval_minutes, 60) * 1.5 + 30, 45) as allow_min
      from public.sync_jobs j join st on st.job_id = j.id
     where j.enabled order by j.sort_order nulls last, j.id
  loop
    is_stale := (f.n_never > 0)
             or (f.oldest_at is null)
             or (extract(epoch from (now() - f.oldest_at)) / 60.0 > f.allow_min)
             or (f.max_consec >= 3);

    if not is_stale then continue; end if;
    stale_n := stale_n + 1;

    feeds := feeds || jsonb_build_object(
      'key',  'sync:' || f.id,
      /* ⚠️ النص ده بالحرف زي ما كان — شاشات قديمة بتعرضه */
      'name', 'مزامنة ' || f.name
              || case when f.n_never > 0 then ' — لم تبدأ بعد'
                      when f.max_consec >= 3
                      then ' — فشلت ' || f.max_consec || ' محاولات متتالية' ||
                           case when f.n_failed < f.n_branches
                                then ' (' || coalesce(f.failed_names, '') || ')' else '' end
                      else '' end,
      -- الحقول الجديدة: الواجهة بتجمّع بيها
      'job',      f.id,
      'job_name', f.name,
      'branches_failed', f.failed_json,
      'rows', f.n_branches, 'last_at', f.oldest_at,
      'age_hours', case when f.oldest_at is null then null
                   else round((extract(epoch from (now() - f.oldest_at)) / 3600.0)::numeric, 1) end,
      'stale', true,
      'reason', case when f.oldest_at is null then 'no_timestamp' else 'stale' end,
      'consec_fail', f.max_consec,
      'interval_minutes', f.interval_minutes);
  end loop;

  if to_regprocedure('public.get_sales_gaps(int,int)') is not null then
    begin
      execute 'select coalesce(public.get_sales_gaps(21, 20) -> ''gaps'', ''[]''::jsonb)' into v_gaps;
    exception when others then v_gaps := '[]'::jsonb;
    end;
  end if;

  return jsonb_build_object(
    'checked_at', now(), 'threshold_hours', p_hours, 'stale_count', stale_n,
    'branches', items, 'feeds', feeds, 'sales_gaps', v_gaps);
end$function$;

notify pgrst, 'reload schema';
