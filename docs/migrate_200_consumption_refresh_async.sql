-- migrate_200_consumption_refresh_async.sql
--
-- رفع شيت المبيعات كان بيفشل بـ57014 (canceling statement due to statement timeout).
--
-- القياس (2026-11-10):
--   get_consumption_rates()           41,571 م.ث
--   سقف دور authenticated              8,000 م.ث
--   bills من sales_items                 374 م.ث
--   base من monthly_sales                 32 م.ث
--   تصنيف الأصناف من stock_flat            83 م.ث
-- يعني الرفع نفسه سريع، والوقت كله في إعادة الحساب اللي كانت بتتنادى
-- جوّه upload_month_sales. والنداء ترانزاكشن واحدة، فالمهلة كانت
-- بترجّع كل حاجة — الشهر مكانش بيتحفظ أصلًا.
--
-- الحل (اختيار المالك): نفصل الرفع عن الحساب. الرفع يحفظ ويرجع فورًا،
-- وإعادة الحساب تحصل في الخلفية — المهام المجدولة مالهاش سقف 8 ثواني.
--
-- ملاحظة: الدالة لسه بطيئة (41 ثانية) ومااتصلحتش — ده فصل مش تسريع.
-- لو اتسرّعت بعدين، ممكن نرجّع الحساب للرفع مباشرة.

-- ═══ ١. حالة الطلب ═══
create table if not exists public.consumption_refresh_state (
  id            boolean primary key default true check (id),
  dirty         boolean     not null default false,
  requested_at  timestamptz,
  requested_by  text,
  last_done_at  timestamptz,
  last_ms       integer
);
insert into public.consumption_refresh_state(id) values (true)
  on conflict (id) do nothing;

alter table public.consumption_refresh_state enable row level security;
drop policy if exists allow_all on public.consumption_refresh_state;
create policy allow_all on public.consumption_refresh_state for all using (true) with check (true);
grant select on public.consumption_refresh_state to authenticated;

-- ═══ ٢. طلب إعادة حساب (بدل تنفيذها فورًا) ═══
create or replace function public.request_consumption_refresh()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v record;
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    perform public.require_app_role(array['admin','manager','pharmacist']);
  end if;

  update public.consumption_refresh_state
     set dirty        = true,
         requested_at = now(),
         requested_by = coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', 'system')
   where id
   returning * into v;

  return jsonb_build_object(
    'dirty', v.dirty, 'requested_at', v.requested_at,
    'last_done_at', v.last_done_at, 'last_ms', v.last_ms);
end $fn$;

revoke all on function public.request_consumption_refresh() from public, anon;
grant execute on function public.request_consumption_refresh() to authenticated, service_role;

-- ═══ ٣. المنفّذ — بيشتغل من المهمة المجدولة (بلا سقف وقت) ═══
create or replace function public.run_pending_consumption_refresh()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare t0 timestamptz; n int;
begin
  if not exists (select 1 from public.consumption_refresh_state where id and dirty) then
    return jsonb_build_object('ran', false);
  end if;

  -- نقفل الصف عشان تشغيلين مايتزاحموش على نفس الطلب
  perform 1 from public.consumption_refresh_state where id for update;

  t0 := clock_timestamp();
  n  := public.refresh_consumption_rates();

  update public.consumption_refresh_state
     set dirty = false, last_done_at = now(),
         last_ms = (extract(epoch from (clock_timestamp() - t0)) * 1000)::int
   where id;

  return jsonb_build_object('ran', true, 'rows', n);
end $fn$;

revoke all on function public.run_pending_consumption_refresh() from public, anon, authenticated;
grant execute on function public.run_pending_consumption_refresh() to service_role;

-- ═══ ٤. الرفع مابقاش يعيد الحساب — بيطلبها بس ═══
create or replace function public.upload_month_sales(p_month text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ins  int;
  v_now  timestamptz := now();
  v_cols text := '';
  v_vals text := '';
  v_sql  text;
  r      record;
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);
  if p_month is null or p_month !~ '^\d{2}-\d{4}$' then
    raise exception 'bad_month_format';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'rows_required';
  end if;

  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      v_cols := v_cols || ', ' || quote_ident(r.code);
      v_vals := v_vals || ', coalesce(nullif(e->>' || quote_literal(r.code)
                       || ','''')::numeric, 0) ' || quote_ident(r.code);
    end if;
  end loop;

  if v_cols = '' then
    raise exception 'مفيش أعمدة فروع في monthly_sales — شغّل sync_branch_sales_columns()';
  end if;

  delete from monthly_sales where month = p_month;

  v_sql :=
       'with raw as ('
    || '  select trim(e->>''code'') itm_code, trim(e->>''name'') itm_name' || v_vals
    || '       , (row_number() over ())::int rn'
    || '    from jsonb_array_elements($1) e'
    || '), cleaned as (select * from raw where itm_code is not null and itm_code <> '''''
    || '), dedup as ('
    || '  select distinct on (itm_code) itm_code, itm_name' || v_cols
    || '    from cleaned order by itm_code, rn desc'
    || ')'
    || ' insert into monthly_sales(itm_code, itm_name' || v_cols || ', month, updated_at)'
    || ' select itm_code, itm_name' || v_cols || ', $2, $3 from dedup';

  execute v_sql using p_rows, p_month, v_now;
  get diagnostics v_ins = row_count;

  -- كان: perform refresh_consumption_rates();  ← 41 ثانية تحت سقف 8
  perform public.request_consumption_refresh();

  return jsonb_build_object('month', p_month, 'inserted', v_ins, 'refresh', 'queued');
end $function$;

-- ═══ ٥. المهمة المجدولة — كل دقيقتين، وماتعملش حاجة لو مفيش طلب ═══
select cron.unschedule('consumption_refresh_pending')
 where exists (select 1 from cron.job where jobname = 'consumption_refresh_pending');

select cron.schedule('consumption_refresh_pending', '*/2 * * * *',
                     'select public.run_pending_consumption_refresh();');

notify pgrst, 'reload schema';
