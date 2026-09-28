-- ═══════════════════════════════════════════════════════════════════
-- مزامنة فارما اوفر سيز على مدار اليوم + كشف الفشل
-- ═══════════════════════════════════════════════════════════════════
-- المشكلة: الجولة الكاملة (224 صفحة × 100 صنف + نداء تفاصيل لكل صنف)
-- ضغطة واحدة تقيلة على API المورّد وعلى الدالة. الحل: نبضة كل ساعة
-- بتاخد 10 صفحات بس (~1000 صنف)، فالكتالوج كله بيتغطّى في يوم.
--
-- وكشف الفشل مبني في التصميم نفسه:
--   • كل نبضة بتكتب صف في pharma_sync_log (نجحت/فشلت + السبب + المدة)
--   • الفشل بيزوّد consecutive_failures ومابيقدّمش next_page — يعني
--     الدفعة الفاشلة بتتعاد في النبضة الجاية بدل ما تتخطى في صمت
--   • running_since بيمنع تداخل نبضتين، وبيسقط بعد 25 دقيقة لو الدالة
--     ماتت من غير ما ترجّع
--   • pharma_sync_status() بترجّع كل ده لشاشة «أسعار وخصومات المخازن»
--
-- ⚠️ الكرون ده بيضرب API مورّد خارجي — على سيرفر التجربة سيبه enabled=false
--    أو ماتعملش صف الـcron أصلًا، عشان مايتشغّلش من مكانين على نفس الحساب.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1) كود الصنف عند المورّد ─────────────────────────────────────
-- الكود ده هو اللي بيتلزق في خانة «ادخل منتجات» عند فارما (مابيقبلوش
-- لصق الاسم)، فشاشة الطلبيات بتنسخه بدل الاسم.
alter table store_item_prices add column if not exists supplier_code text;

create or replace function public.pharma_codes_upsert(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  with incoming as (
    select distinct on (btrim(item_name))
           btrim(item_name) item_name, nullif(btrim(supplier_code),'') supplier_code
      from jsonb_to_recordset(p_rows) as x(item_name text, supplier_code text)
     where coalesce(btrim(item_name),'') <> '' and coalesce(btrim(supplier_code),'') <> ''
     order by btrim(item_name)
  ), up as (
    update store_item_prices sp
       set supplier_code = i.supplier_code
      from incoming i
     where sp.store = 'فارما اوفر سيز'
       and sp.item_name = i.item_name
       and sp.supplier_code is distinct from i.supplier_code
    returning 1
  )
  select count(*) into n from up;
  return n;
end $$;

-- الأسعار بتحفظ الكود معاها كمان؛ coalesce عشان دفعة من غير كود
-- ماتمسحش كود اتجاب قبل كده.
create or replace function public.pharma_prices_upsert(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  with incoming as (
    select distinct on (item_name)
      btrim(item_name) as item_name, price, discount_perc, available,
      nullif(btrim(supplier_code), '') as supplier_code
    from jsonb_to_recordset(p_rows)
      as x(item_name text, price numeric, discount_perc numeric, available boolean, supplier_code text)
    where coalesce(btrim(item_name),'') <> ''
    order by item_name, (price*(1-coalesce(discount_perc,0)/100)) asc nulls last
  ),
  up as (
    insert into store_item_prices (item_name, store, price, discount_perc, available, supplier_code, updated_at)
    select item_name, 'فارما اوفر سيز', price, discount_perc, coalesce(available,true), supplier_code, now()
    from incoming
    on conflict (item_name, store) do update
      set price = excluded.price,
          discount_perc = excluded.discount_perc,
          available = excluded.available,
          supplier_code = coalesce(excluded.supplier_code, store_item_prices.supplier_code),
          updated_at = now()
    returning 1
  )
  select count(*) into n from up;
  return n;
end $$;

-- ── 2) حالة المزامنة + سجلّها ────────────────────────────────────
create table if not exists public.pharma_sync_state (
  id                   integer primary key default 1 check (id = 1),
  enabled              boolean not null default true,
  pages_per_run        integer not null default 10,
  next_page            integer not null default 0,
  total_pages          integer,
  cycle_no             integer not null default 0,
  cycle_started_at     timestamptz,
  running_since        timestamptz,
  last_tick_at         timestamptz,
  last_run_at          timestamptz,
  last_ok              boolean,
  last_error           text,
  consecutive_failures integer not null default 0
);
insert into public.pharma_sync_state (id) values (1) on conflict (id) do nothing;

create table if not exists public.pharma_sync_log (
  id           bigserial primary key,
  run_at       timestamptz not null default now(),
  from_page    integer,
  to_page      integer,
  total_pages  integer,
  processed    integer,
  upserted     integer,
  codes        integer,
  failed_pages integer,
  detail_fails integer,
  ok           boolean,
  error        text,
  seconds      numeric
);
create index if not exists pharma_sync_log_run_at_idx on public.pharma_sync_log (run_at desc);

alter table public.pharma_sync_state enable row level security;
alter table public.pharma_sync_log   enable row level security;
drop policy if exists pharma_sync_state_rw on public.pharma_sync_state;
drop policy if exists pharma_sync_log_ro   on public.pharma_sync_log;
create policy pharma_sync_state_rw on public.pharma_sync_state for all to authenticated using (true) with check (true);
create policy pharma_sync_log_ro   on public.pharma_sync_log   for select to authenticated using (true);

-- GRANT والـpolicy فحصين منفصلين — الدالة بتشتغل بـservice_role وهو
-- في المشروع ده مابياخدش كتابة تلقائيًا على الجداول الجديدة.
grant select, update on public.pharma_sync_state to authenticated, service_role;
grant select on public.pharma_sync_log to authenticated;
grant insert, select on public.pharma_sync_log to service_role;
grant usage, select on sequence public.pharma_sync_log_id_seq to service_role;

-- ── 3) المفتاح اللي الكرون بينادي بيه الدالة ─────────────────────
-- محفوظ في vault مش في متغيّرات البيئة، عشان مايتنقلش بره القاعدة.
-- (سطر الإنشاء لمرة واحدة — بدّل القيمة بمفتاح عشوائي طويل)
-- select vault.create_secret('<random-key>', 'pharma_sync_key', 'مفتاح نداء pharma_sync من الكرون');

create or replace function public.is_pharma_sync_key(p_key text)
returns boolean language sql security definer set search_path to 'public','vault' as $$
  select coalesce(p_key <> '' and exists (
    select 1 from vault.decrypted_secrets where name = 'pharma_sync_key' and decrypted_secret = p_key
  ), false)
$$;
revoke execute on function public.is_pharma_sync_key(text) from public, anon, authenticated;
grant execute on function public.is_pharma_sync_key(text) to service_role;

-- ── 4) النبضة ────────────────────────────────────────────────────
create or replace function public.pharma_sync_tick()
returns text language plpgsql security definer
set search_path to 'public','extensions','vault' as $$
declare st public.pharma_sync_state; k text; rid bigint;
begin
  select * into st from public.pharma_sync_state where id = 1;
  if not st.enabled then return 'disabled'; end if;
  -- حارس التداخل: نبضة شغّالة لسه = مانبعتش تانية
  if st.running_since is not null and st.running_since > now() - interval '25 minutes' then
    return 'busy_since_' || st.running_since::text;
  end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'pharma_sync_key';
  if k is null then return 'no_key'; end if;

  update public.pharma_sync_state set running_since = now(), last_tick_at = now() where id = 1;
  select net.http_post(
    url := 'https://rxtjoqulmgkkcohmgzgi.supabase.co/functions/v1/pharma_sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-key', k),
    body := jsonb_build_object('scheduled', true),
    timeout_milliseconds := 180000
  ) into rid;
  return 'queued:' || rid;
end $$;
revoke execute on function public.pharma_sync_tick() from public, anon;
grant execute on function public.pharma_sync_tick() to authenticated;

-- ── 5) الحالة للشاشة ─────────────────────────────────────────────
create or replace function public.pharma_sync_status()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'enabled',        s.enabled,
    'next_page',      s.next_page,
    'total_pages',    s.total_pages,
    'pages_per_run',  s.pages_per_run,
    'cycle_no',       s.cycle_no,
    'cycle_started_at', s.cycle_started_at,
    'last_run_at',    s.last_run_at,
    'last_ok',        s.last_ok,
    'last_error',     s.last_error,
    'consecutive_failures', s.consecutive_failures,
    'running',        (s.running_since is not null and s.running_since > now() - interval '25 minutes'),
    'stale_hours',    round(extract(epoch from (now() - coalesce(s.last_run_at, s.cycle_started_at, now()))) / 3600.0, 1),
    'ok_last_24h',    (select count(*) from pharma_sync_log l where l.run_at > now() - interval '24 hours' and l.ok),
    'fail_last_24h',  (select count(*) from pharma_sync_log l where l.run_at > now() - interval '24 hours' and not l.ok),
    'recent',         (select coalesce(jsonb_agg(x order by x->>'run_at' desc), '[]'::jsonb) from (
                         select jsonb_build_object('run_at', l.run_at, 'from_page', l.from_page, 'to_page', l.to_page,
                                'ok', l.ok, 'upserted', l.upserted, 'codes', l.codes,
                                'failed_pages', l.failed_pages, 'error', left(l.error, 200), 'seconds', l.seconds) x
                           from pharma_sync_log l order by l.run_at desc limit 12) t)
  ) from pharma_sync_state s where s.id = 1
$$;
revoke execute on function public.pharma_sync_status() from public, anon;
grant execute on function public.pharma_sync_status() to authenticated;

-- ── 6) الجدولة: نبضة كل ساعة في الدقيقة 40 ───────────────────────
-- 24 نبضة × 10 صفحات = 240 صفحة/يوم > 224 صفحة الكتالوج = دورة كاملة يوميًا.
-- select cron.schedule('pharma_sync_hourly', '40 * * * *', $cron$ select public.pharma_sync_tick(); $cron$);
