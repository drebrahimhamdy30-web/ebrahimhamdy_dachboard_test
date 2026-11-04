/* ═══════════════════════════════════════════════════════════════════
   تنبيه المزامنة: يفرّق بين رعشة شبكة وعطل حقيقي
   ═══════════════════════════════════════════════════════════════════
   ── العطل في الحارس نفسه ────────────────────────────────────────
   `migrate_181` كان بيحوّش أي مهمة **آخر محاولة فيها فشلت**، حتى لو
   المحاولة اللي قبلها نجحت والبيانات لسه طازة. النتيجة إن الشريط
   الأحمر طلع لكل الموظفين على ٤ مهام في السيوف، والواقع:

     مهمة              آخر نجاح   حد السماح   محاولات فاشلة متتالية
     تحويلات الفروع     ٩٤ د       ١٢٠ د       ١
     تغيّرات الأسعار    ٩٤ د       ١٢٠ د       ١
     تعديلات المخزون    ٩٥ د       ١٢٠ د       ١
     المبيعات المحفوظة  ٧٩ د       ١٢٠ د       ١

   يعني مفيش بيانات متأخرة أصلًا. والأخطاء كلها **شبكة مش SQL**:
   «semaphore timeout» و«network name is no longer available»
   و«pre-login handshake» — رعشات في الوصل لجهاز الفرع.

   ⚠️ **تنبيه بيطلع كل شوية بيتعلّم الموظف إنه يتجاهله** — وساعتها
      مابيقولش حاجة لما يبقى العطل حقيقي. الحارس اللي بيصرخ كتير
      أسوأ من اللي ساكت.

   ── القاعدة الجديدة ─────────────────────────────────────────────
   يتحوّش لو:
     • المهمة ما اشتغلتش خالص على الفرع ده، أو
     • **آخر نجاح** أقدم من حد السماح (دورة ونص + نص ساعة)، أو
     • **٣ محاولات متتالية فاشلة** — عطل مستمر حتى لو لسه جوّه السماح.

   الشرط التاني هو مقياس «البيانات متأخرة» الحقيقي، والتالت بيمسك
   العطل المستمر بدري في المهام السريعة (٣ محاولات = دقايق) من غير
   ما يرنّ على رعشة واحدة.

   عطل الـ403 اللي استمر يومين (migrate_165) كان هيتمسك بالشرطين:
   التتابع خلال ٣ جولات، والعمر خلال ٣٦ ساعة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* الحساب بيلفّ على آخر ٣ أيام لكل (مهمة، فرع) — الفهرس على الوقت
   موجود، وده بيخلي النافذة صغيرة بدل مسح الجدول كله. */
create index if not exists ix_sync_runs_job_branch_id
  on public.sync_runs (job_id, branch, id desc);

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
      items := items || jsonb_build_object('code', r.code, 'name', r.name, 'rows', 0,
        'last_at', null, 'age_hours', null, 'stale', true, 'reason', 'no_table');
      stale_n := stale_n + 1;
      continue;
    end if;
    execute format('select count(*), max(updated_at) from public.%I', tbl) into n, last_at;
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
    /* متتالية الفشل = عدد الجولات قبل أول نجاح من الأحدث للأقدم */
    cons as (
      select t.job_id, t.branch, coalesce(o.rn_ok, t.n + 1) - 1 as consec_fail
        from tot t left join ok1 o on o.job_id = t.job_id and o.branch = t.branch
    ),
    st as (
      select s.job_id,
             min(s.last_sync_at)                               as oldest_at,
             count(*)                                          as n_branches,
             count(*) filter (where s.last_sync_at is null)    as n_never,
             coalesce(max(c.consec_fail), 0)                   as max_consec,
             string_agg(coalesce(b.name, s.branch), '، ' order by s.branch)
               filter (where c.consec_fail >= 3)               as failed_names,
             count(*) filter (where c.consec_fail >= 3)        as n_failed
        from public.sync_branch_state s
        left join public.branches b on b.code = s.branch
        left join cons c on c.job_id = s.job_id and c.branch = s.branch
       where s.enabled
       group by s.job_id
    )
    select j.id, j.name, j.interval_minutes, st.oldest_at, st.n_branches,
           st.n_failed, st.n_never, st.failed_names, st.max_consec,
           greatest(coalesce(j.interval_minutes, 60) * 1.5 + 30, 45) as allow_min
      from public.sync_jobs j join st on st.job_id = j.id
     where j.enabled order by j.sort_order nulls last, j.id
  loop
    /* ⚠️ مش «آخر محاولة فشلت»: ده بيرنّ على رعشة شبكة واحدة.
       المقياس هو تأخّر آخر **نجاح**، أو فشل متتالي مستمر. */
    is_stale := (f.n_never > 0)
             or (f.oldest_at is null)
             or (extract(epoch from (now() - f.oldest_at)) / 60.0 > f.allow_min)
             or (f.max_consec >= 3);

    if not is_stale then continue; end if;
    stale_n := stale_n + 1;

    feeds := feeds || jsonb_build_object(
      'key',  'sync:' || f.id,
      'name', 'مزامنة ' || f.name
              || case when f.n_never > 0 then ' — لم تبدأ بعد'
                      when f.max_consec >= 3
                      then ' — فشلت ' || f.max_consec || ' محاولات متتالية' ||
                           case when f.n_failed < f.n_branches
                                then ' (' || coalesce(f.failed_names, '') || ')' else '' end
                      else '' end,
      'rows', f.n_branches, 'last_at', f.oldest_at,
      'age_hours', case when f.oldest_at is null then null
                   else round((extract(epoch from (now() - f.oldest_at)) / 3600.0)::numeric, 1) end,
      'stale', true,
      'reason', case when f.oldest_at is null then 'no_timestamp' else 'stale' end,
      'consec_fail', f.max_consec,
      'interval_minutes', f.interval_minutes);
  end loop;

  /* فجوات المبيعات دالة اختيارية — مش موجودة على الذاتي */
  if to_regprocedure('public.get_sales_gaps(int,int)') is not null then
    begin
      execute 'select coalesce(public.get_sales_gaps(21, 20) -> ''gaps'', ''[]''::jsonb)' into v_gaps;
    exception when others then v_gaps := '[]'::jsonb;
    end;
  end if;

  return jsonb_build_object(
    'checked_at', now(), 'threshold_hours', p_hours, 'stale_count', stale_n,
    'branches', items, 'feeds', feeds, 'sales_gaps', v_gaps);
end$fn$;

notify pgrst, 'reload schema';
