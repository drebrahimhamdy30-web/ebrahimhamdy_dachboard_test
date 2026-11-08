/* ═══════════════════════════════════════════════════════════════════
   الموقف اليومي: دالة الأرقام + اللقطة اليومية
   ═══════════════════════════════════════════════════════════════════
   شاشة واحدة تجمع أرقام المالك من مصادر متفرّقة:

     صافي الموقف = (مخزون بالتكلفة + كاش + مديونية عملاء) − مستحق الموردين

   ── ليه لقطة يومية مش حساب بأثر رجعي ────────────────────────────
   اللقطة لوحدها ماتقولش حاجة — اللي بيقول هو الحركة: مديونية
   العملاء زادت ٤٠ ألف امبارح، الكاش نزل، المخزون كبر. وماينفعش
   نحسب «أمبارح» دلوقتي لأن المصادر كلها **لقطة حاضرة**:
   `purchase_vendors.ven_current_credit` و`eplus_safes.balance`
   و`stock_*` كلهم بيتكتبوا فوق نفسهم كل مزامنة ومفيش تاريخ.
   فاللقطة بتتكتب كل ليلة في `daily_position` وبتفضل.

   ── التكلفة مشتقّة، مش مخزّنة ─────────────────────────────────────
   جداول المخزون فيها **سعر البيع بس** (`itm_sell_price_big`).
   التكلفة بتتاخد من **آخر سعر شراء** للصنف في
   `purchase_invoice_items` — فرعه الأول، وإلا أي فرع (الفرع الجديد
   مشترياته قليلة فبيستفيد من أسعار الفروع التانية).
   التغطية ~٩٣٪ من قيمة المخزون، والباقي بيتقدّر بنفس نسبة التكلفة
   للبيع بتاعة المغطّى — والدالة بترجّع `cost_coverage_pct` عشان
   الرقم يتقال تقريبي على الشاشة مش يتقدّم كأنه مقطوع بيه.

   ⚠️ `sto_qty_big` و`itm_sell_price_big` و`itm_pur_price` كلهم
      **بالعلبة** — مفيش تحويل وحدات هنا. راجع [[unit-trap-strips-vs-boxes]].

   ⚠️ ممنوع view على جداول المخزون (بتتعمل rename كل مزامنة) —
      فالقراءة بـSQL ديناميكي جوّه الدالة. راجع [[no-views-on-swapped-tables]].

   ── الصلاحية ─────────────────────────────────────────────────────
   الشاشة للمالك: `admin` بس. الحارس على السيرفر مش إخفاء زرار.
   `admin` بيعدّي دايمًا زي باقي النظام، وأي دور تاني لازم يكون له
   صف `can_view` في `page_permissions`.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.daily_position (
  d              date        not null,
  branch         text        not null,
  stock_cost     numeric     not null default 0,
  stock_sell     numeric     not null default 0,
  cash           numeric     not null default 0,
  customers_debt numeric     not null default 0,
  vendors_due    numeric     not null default 0,
  net            numeric     not null default 0,
  captured_at    timestamptz not null default now(),
  primary key (d, branch)
);

comment on table public.daily_position is
  'لقطة الموقف المالي بالفرع كل ليلة — المصادر كلها بتتكتب فوق نفسها فمفيش تاريخ غير ده';

alter table public.daily_position enable row level security;
drop policy if exists daily_position_read on public.daily_position;
create policy daily_position_read on public.daily_position
  for select to authenticated using (true);

revoke all on public.daily_position from public, anon;
grant select on public.daily_position to authenticated;
grant all    on public.daily_position to service_role;

/* فهرس آخر سعر شراء للصنف — الدالة بتعمل distinct on (itm_code) */
create index if not exists ix_pii_code_branch_pth
  on public.purchase_invoice_items (itm_code, branch, pth_id desc, ptd_id desc)
  where itm_pur_price > 0;

/* ─────────────────────────────────────────────────────────────────
   الدالة: بترجّع الموقف الحالي + مقارنة بآخر لقطة قبل النهارده
   ───────────────────────────────────────────────────────────────── */
create or replace function public.get_owner_position()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_role text := public.jwt_app_role();
  r       record;
  tbl     text;
  v_rows  jsonb := '[]'::jsonb;
  v_sell  numeric; v_cost numeric; v_cov numeric; v_upd timestamptz;
  v_cash  numeric; v_cust numeric; v_vend numeric;
  v_prev  jsonb;
  v_mtd   jsonb;
  v_fresh jsonb;
  /* ⚠️ تاريخ القاهرة مش تاريخ السيرفر (UTC): بين ١٢ و٢ بالليل
     بتوقيت القاهرة السيرفر لسه في «امبارح»، فمقارنة «آخر لقطة قبل
     النهارده» كانت هتقارن اليوم بنفسه. */
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  if v_role is null then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  if v_role <> 'admin' and not exists (
       select 1 from page_permissions pp
        where pp.role = v_role and pp.page_key = 'owner_position' and pp.can_view) then
    raise exception 'غير مصرّح: الشاشة دي للمالك' using errcode = '42501';
  end if;

  for r in
    select code, name from branches
     where is_active and coalesce(code,'') <> ''
     order by sort_order nulls last, name
  loop
    tbl := 'stock_' || r.code;
    v_sell := 0; v_cost := 0; v_cov := null; v_upd := null;

    if to_regclass('public.' || quote_ident(tbl)) is not null then
      /* آخر سعر شراء: الفرع الأول، وإلا أي فرع */
      execute format($q$
        with lc_br as (
          select distinct on (itm_code) itm_code, itm_pur_price c
            from purchase_invoice_items
           where branch = %L and itm_pur_price > 0 and coalesce(btrim(itm_code),'') <> ''
           order by itm_code, pth_id desc, ptd_id desc),
        lc_any as (
          select distinct on (itm_code) itm_code, itm_pur_price c
            from purchase_invoice_items
           where itm_pur_price > 0 and coalesce(btrim(itm_code),'') <> ''
           order by itm_code, pth_id desc, ptd_id desc),
        s as (
          select itm_code,
                 coalesce(nullif(btrim(sto_qty_big::text),'')::numeric,0)        q,
                 coalesce(nullif(btrim(itm_sell_price_big::text),'')::numeric,0) p,
                 updated_at
            from public.%I)
        select
          coalesce(sum(s.q * s.p), 0),
          coalesce(sum(s.q * coalesce(lc_br.c, lc_any.c, 0)), 0),
          round(100.0 * coalesce(sum(case when coalesce(lc_br.c, lc_any.c) is not null
                                          then s.q * s.p else 0 end), 0)
                      / nullif(sum(s.q * s.p), 0), 1),
          max(s.updated_at)
          from s
          left join lc_br  on lc_br.itm_code  = s.itm_code
          left join lc_any on lc_any.itm_code = s.itm_code
      $q$, r.code, tbl)
      into v_sell, v_cost, v_cov, v_upd;

      /* الجزء غير المغطّى يتقدّر بنفس نسبة التكلفة للبيع بتاعة المغطّى */
      if coalesce(v_cov,0) > 0 and v_cov < 100 and v_sell > 0 then
        v_cost := round(v_cost * 100.0 / v_cov, 2);
      end if;
    end if;

    select coalesce(sum(coalesce(v.ven_current_credit,0) + coalesce(a.adjust,0)), 0)
      into v_vend
      from purchase_vendors v
      left join vendor_balance_adjust a
             on a.branch = v.branch and a.ven_name_ar = v.ven_name_ar
     where v.branch = r.code;

    select coalesce(sum(greatest(balance,0)), 0) into v_cust
      from (
        select case r.code
                 when 'mamora' then coalesce(nullif(btrim(c.balance),'')::numeric,0)
                 when 'san'    then coalesce(nullif(btrim(c.balance_san),'')::numeric,0)
                 when 'bishr'  then coalesce(nullif(btrim(c.balance_bishr),'')::numeric,0)
                 when 'seyouf' then coalesce(nullif(btrim(c.balance_seyouf),'')::numeric,0)
                 else 0 end as balance
          from customers c) t;

    /* ⚠️ الجدولين دول موجودين على السحابة بس — السيرفر الذاتي
       مابيتعملش فيه الجداول الجديدة تلقائيًا (ذاكرة
       cloud-sync-never-creates-tables). من غير الحارس ده الشاشة
       كلها كانت هتقع على التست برسالة relation does not exist
       بدل ما تعرض اللي متاح وتسيب الباقي صفر. */
    v_cash := 0;
    if to_regclass('public.eplus_safes') is not null then
      select coalesce(sum(balance), 0) into v_cash
        from eplus_safes where branch = r.code and coalesce(active,0) = 1;
    end if;

    v_rows := v_rows || jsonb_build_object(
      'code', r.code, 'name', r.name,
      'stock_cost', round(coalesce(v_cost,0)),
      'stock_sell', round(coalesce(v_sell,0)),
      'cost_coverage_pct', v_cov,
      'cash', round(coalesce(v_cash,0)),
      'customers_debt', round(coalesce(v_cust,0)),
      'vendors_due', round(coalesce(v_vend,0)),
      'net', round(coalesce(v_cost,0) + coalesce(v_cash,0)
                 + coalesce(v_cust,0) - coalesce(v_vend,0)),
      'stock_updated_at', v_upd);
  end loop;

  /* آخر لقطة **قبل** النهارده — ممكن تكون امبارح أو أقدم لو الكرون فات */
  select jsonb_build_object(
           'd', max(d),
           'rows', (select coalesce(jsonb_object_agg(branch, to_jsonb(p) - 'd' - 'captured_at'),'{}'::jsonb)
                      from daily_position p
                     where p.d = (select max(d) from daily_position where d < v_today)))
    into v_prev
    from daily_position where d < v_today;

  /* الشهر الجاري من الربحية المزامنة (أساس c = تاريخ التسليم) */
  if to_regclass('public.eplus_monthly_pnl') is not null then
  select jsonb_build_object(
           'ym', ym,
           'sales', round(sum(aft)),
           'profit', round(sum(aft - cost)),
           'margin', round(100.0 * sum(aft - cost) / nullif(sum(aft),0), 1))
    into v_mtd
    from eplus_monthly_pnl
   where basis = 'c' and ym = to_char(v_today, 'YYYY-MM')
   group by ym;
  end if;

  /* ⚠️ الحارس لازم يكون IF منفصل مش CASE جوّه الاستعلام:
     بوستجرس بيخطط الاستعلام كله فبيقع على الجدول الناقص حتى لو
     الشرط مكانش هيوصله. جوّه IF الكتلة مابتتخططش أصلًا. */
  v_fresh := jsonb_build_object(
    'customers', (select max(updated_at) from customers),
    'vendors',   (select max(synced_at)  from purchase_vendors),
    'pnl', null, 'cash', null);
  if to_regclass('public.eplus_monthly_pnl') is not null then
    select jsonb_set(v_fresh, '{pnl}', to_jsonb(max(synced_at))) into v_fresh from eplus_monthly_pnl;
  end if;
  if to_regclass('public.eplus_safes') is not null then
    select jsonb_set(v_fresh, '{cash}', to_jsonb(max(synced_at))) into v_fresh from eplus_safes;
  end if;

  return jsonb_build_object(
    'as_of', now(), 'branches', v_rows, 'prev', v_prev,
    'mtd', coalesce(v_mtd, '{}'::jsonb), 'freshness', v_fresh);
end$fn$;

revoke all on function public.get_owner_position() from public, anon;
grant execute on function public.get_owner_position() to authenticated;

/* ─────────────────────────────────────────────────────────────────
   اللقطة اليومية — تتكتب كل ليلة وتُحدَّث لو اتنادت تاني نفس اليوم
   ───────────────────────────────────────────────────────────────── */
create or replace function public.snapshot_daily_position(p_day date default null)
returns integer
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_day date := coalesce(p_day, (now() at time zone 'Africa/Cairo')::date);
  v_pos jsonb;
  v_n   int := 0;
begin
  /* الدالة محروسة بالدور، والكرون بيشتغل بدون JWT — نلبّس الدور مؤقتًا */
  perform set_config('request.jwt.claims', '{"user_role":"admin"}', true);
  v_pos := public.get_owner_position();

  insert into daily_position (d, branch, stock_cost, stock_sell, cash,
                              customers_debt, vendors_due, net, captured_at)
  select v_day, b->>'code',
         (b->>'stock_cost')::numeric, (b->>'stock_sell')::numeric,
         (b->>'cash')::numeric, (b->>'customers_debt')::numeric,
         (b->>'vendors_due')::numeric, (b->>'net')::numeric, now()
    from jsonb_array_elements(v_pos->'branches') b
  on conflict (d, branch) do update set
    stock_cost = excluded.stock_cost, stock_sell = excluded.stock_sell,
    cash = excluded.cash, customers_debt = excluded.customers_debt,
    vendors_due = excluded.vendors_due, net = excluded.net,
    captured_at = excluded.captured_at;

  get diagnostics v_n = row_count;
  return v_n;
end$fn$;

revoke all on function public.snapshot_daily_position(date) from public, anon, authenticated;

notify pgrst, 'reload schema';

/* ─────────────────────────────────────────────────────────────────
   الجدولة: لقطة كل ساعة تكتب فوق صف اليوم
   ───────────────────────────────────────────────────────────────── */
/* ⚠️ مش لقطة واحدة الساعة ١٢ بالليل: الجدولة بتوقيت السيرفر (UTC)
   ومصر بتغيّر الساعة صيفًا، فأي ساعة ثابتة بتزحف ساعة وتكتب اللقطة
   على اليوم الغلط. اللقطة كل ساعة بتكتب فوق نفس صف اليوم، فآخر
   كتابة في اليوم هي قيمة آخر اليوم — ولو ساعة فاتت اللي بعدها
   بتغطّيها. راجع [[sales-sync-silent-day-loss]]. */
select cron.unschedule('owner_position_hourly')
 where exists (select 1 from cron.job where jobname = 'owner_position_hourly');

select cron.schedule('owner_position_hourly', '35 * * * *',
                     $$select public.snapshot_daily_position()$$);

/* ─────────────────────────────────────────────────────────────────
   تسجيل الشاشة — للمالك (admin) بس
   ───────────────────────────────────────────────────────────────── */
insert into public.app_pages (key, file, title, section, sort_order, is_active)
values ('owner_position', 'owner_position.html', 'الموقف اليومي',
        'الحسابات والخزينة', 627, true)
on conflict (key) do update set
  file = excluded.file, title = excluded.title,
  section = excluded.section, sort_order = excluded.sort_order,
  is_active = true;

/* ⚠️ صف بلا can_view = شاشة مخفية بصمت. التسجيل بالدالة الرسمية. */
select public.register_page_roles('owner_position',
         array['admin'],   -- عرض
         array['admin'],   -- تعديل (مفيش تعديل فيها، بس للاتساق)
         array['admin']);  -- كل الفروع

notify pgrst, 'reload schema';
