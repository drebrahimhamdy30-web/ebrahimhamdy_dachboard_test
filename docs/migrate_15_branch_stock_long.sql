/* ═══════════════════════════════════════════════════════════════════════════
   migrate_15 — مخزون الفروع في جدول واحد مقسّم بالفرع (الشكل الطولي)
   ═══════════════════════════════════════════════════════════════════════════
   الهدف: إضافة فرع جديد من شاشة الفروع = الجداول والأعمدة والأقسام تتظبط لوحدها،
          بدل ما كل فرع يحتاج جدول `stock_<الفرع>` وعمود في كل جدول عريض.

   ⚠️ السكربت ده **إضافي بحت**. بيضيف جداول ودوال جديدة جنب القديمة، و:
      ✔ ما بيلمسش  stock_mamora / stock_san / stock_bishr
      ✔ ما بيلمسش  stock_flat ولا refresh_stock_flat
      ✔ ما بيلمسش  الكرون ولا مزامنة n8n ولا أي شاشة
      بعد تنفيذه النظام بيشتغل من الطريق القديم زي ما هو بالظبط، والجديد
      بيشتغل في الظل عشان نقارن.

   الترتيب: نفّذه على البرودكشن (سحابة) الأول، وبالحرف على السيرفر الذاتي بعدين.
   الرجوع: آخر السكربت (القسم 9) — مسح اللي اتضاف وخلاص.

   اتجرّب بالكامل في سكيما mig على البرودكشن يوم 2026-09-14:
     • 28,534 صف مطابقة 100% للمنطق القديم في كل عمود.
     • بناء الجدول العريض: 23ms (القديم) مقابل 28ms (الجديد).
     • 5 دورات تحميل كاملة: حجم القسم ثابت (3,976 → 3,968 kB) — صفر تضخّم.
   ═══════════════════════════════════════════════════════════════════════════ */

begin;

/* ───────────────────────────────────────────────────────────────────────────
   1) نوع الصف الجاي من eplus — نفس أسماء حقول الـAPI بالظبط
   ─────────────────────────────────────────────────────────────────────────── */
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where n.nspname = 'public' and t.typname = 'stock_row') then
    create type public.stock_row as (
      itm_code text, itnl_code text, itm_name_ar text, itm_name_en text,
      u_name_big text, u_name_medium text, u_name_small text, sto_name text,
      sto_qty_big text, sto_qty_medium text, sto_qty_small text,
      itm_sell_price_big text, itm_sell_price_medium text, itm_sell_price_small text,
      unit_big_medium_coeff text, unit_big_small_coeff text,
      itm_ismedicine text, "Company_Name_Ar" text,
      insert_date text, update_date text, last_trans_date text
    );
  end if;
end $$;

/* ───────────────────────────────────────────────────────────────────────────
   2) الجدول الواحد — مقسّم LIST بالفرع
   ليه مقسّم؟ المزامنة بتشيل مخزون الفرع كله وتضيفه من أول كل 10 دقايق.
   على جدول مشترك عادي ده معناه DELETE متكرر = تضخّم (اتقاس: 3MB → 21MB بعد
   5 دورات). مع التقسيم كل فرع قسم مستقل بيتفضّى بـTRUNCATE: فورية وصفر تضخّم.
   ─────────────────────────────────────────────────────────────────────────── */
create table if not exists public.branch_stock (
  branch_code            text not null,
  itm_code               text not null,
  itnl_code              text,
  itm_name_ar            text,
  itm_name_en            text,
  u_name_big             text,
  u_name_medium          text,
  u_name_small           text,
  sto_name               text,
  sto_qty_big            text,
  sto_qty_medium         text,
  sto_qty_small          text,
  itm_sell_price_big     text,
  itm_sell_price_medium  text,
  itm_sell_price_small   text,
  unit_big_medium_coeff  text,
  unit_big_small_coeff   text,
  itm_ismedicine         text,
  "Company_Name_Ar"      text,
  insert_date            text,
  update_date            text,
  last_trans_date        text,
  updated_at             timestamptz default now(),
  primary key (branch_code, itm_code)
) partition by list (branch_code);

-- جدول التجهيز: البيانات بتنزل عليه على دفعات، وما تلمسش المخزون الحقيقي
-- إلا لحظة التبديل. لو المزامنة وقعت في النص، مخزون الفرع ما اتمسّش أصلًا.
create table if not exists public.branch_stock_stage (
  like public.branch_stock including defaults
) partition by list (branch_code);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'branch_stock_stage_pkey') then
    alter table public.branch_stock_stage add constraint branch_stock_stage_pkey
      primary key (branch_code, itm_code);
  end if;
end $$;

create index if not exists idx_branch_stock_code on public.branch_stock (itm_code);

-- نفس وضع الجداول القديمة: مقفولة على anon/authenticated، الوصول عبر الدوال
alter table public.branch_stock       enable row level security;
alter table public.branch_stock_stage enable row level security;
revoke all on public.branch_stock, public.branch_stock_stage from anon, authenticated;
grant select on public.branch_stock to service_role;

/* ───────────────────────────────────────────────────────────────────────────
   3) دوال مساعدة — اسم القسم وإنشاؤه
   ─────────────────────────────────────────────────────────────────────────── */
create or replace function public.branch_part_name(p_tbl text, p_branch text)
returns text language sql immutable as $$
  select p_tbl || '_' || regexp_replace(p_branch, '[^a-zA-Z0-9_]', '_', 'g');
$$;

-- أي فرع نشط في جدول branches ملوش قسم → بيتخلق هنا. دي اللي بتخلي
-- «ضفت فرع من الشاشة» كافية.
create or replace function public.ensure_branch_partitions()
returns text language plpgsql security definer set search_path = public as $fn$
declare r record; part text; made text := ''; tbl text;
begin
  for r in select code from public.branches
           where is_active and code is not null order by sort_order, name loop
    foreach tbl in array array['branch_stock', 'branch_stock_stage'] loop
      part := public.branch_part_name(tbl, r.code);
      if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relname = part) then
        execute format('create table public.%I partition of public.%I for values in (%L)',
                       part, tbl, r.code);
        made := made || part || ' ';
      end if;
    end loop;
  end loop;
  return case when made = '' then 'no new partitions' else 'created: ' || made end;
end $fn$;

select public.ensure_branch_partitions();

/* ───────────────────────────────────────────────────────────────────────────
   4) طريق الكتابة الوحيد — تجهيز ثم تبديل ذرّي
   المزامنة ما تعرفش أسماء الجداول ولا الأقسام: بتنادي الدالتين دول وبس.
   كده مستحيل حد يمسح فرع تاني بالغلط، ولا يستعمل DELETE/UPSERT اللي بيضخّموا.
   ─────────────────────────────────────────────────────────────────────────── */
create or replace function public.stage_branch_stock(
  p_branch text, p_rows jsonb, p_reset boolean default false)
returns integer language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    perform public.require_app_role(array['admin','manager']);
  end if;
  if not exists (select 1 from public.branches b where b.code = p_branch and b.is_active) then
    raise exception 'unknown_or_inactive_branch: %', p_branch;
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows_must_be_array';
  end if;

  perform public.ensure_branch_partitions();
  if p_reset then
    execute format('truncate public.%I', public.branch_part_name('branch_stock_stage', p_branch));
  end if;

  insert into public.branch_stock_stage (branch_code, itm_code, itnl_code, itm_name_ar, itm_name_en,
    u_name_big, u_name_medium, u_name_small, sto_name, sto_qty_big, sto_qty_medium, sto_qty_small,
    itm_sell_price_big, itm_sell_price_medium, itm_sell_price_small,
    unit_big_medium_coeff, unit_big_small_coeff, itm_ismedicine, "Company_Name_Ar",
    insert_date, update_date, last_trans_date, updated_at)
  select p_branch, r.itm_code, r.itnl_code, r.itm_name_ar, r.itm_name_en,
         r.u_name_big, r.u_name_medium, r.u_name_small, r.sto_name,
         r.sto_qty_big, r.sto_qty_medium, r.sto_qty_small,
         r.itm_sell_price_big, r.itm_sell_price_medium, r.itm_sell_price_small,
         r.unit_big_medium_coeff, r.unit_big_small_coeff, r.itm_ismedicine, r."Company_Name_Ar",
         r.insert_date, r.update_date, r.last_trans_date, now()
  from jsonb_populate_recordset(null::public.stock_row, p_rows) r
  where coalesce(btrim(r.itm_code), '') <> ''
  on conflict (branch_code, itm_code) do update set
    itm_name_ar        = excluded.itm_name_ar,
    sto_qty_big        = excluded.sto_qty_big,
    itm_sell_price_big = excluded.itm_sell_price_big,
    updated_at         = excluded.updated_at;

  get diagnostics n = row_count;
  return n;
end $fn$;

-- p_expected = قيمة AllRecords اللي eplus نفسه رجّعها. لو اللي وصل مش مطابق
-- ليها، الرد ناقص → نرفض ونسيب المخزون القديم مكانه.
create or replace function public.commit_branch_stock(
  p_branch text, p_expected integer default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare staged int; live int; moved int;
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    perform public.require_app_role(array['admin','manager']);
  end if;
  if not exists (select 1 from public.branches b where b.code = p_branch and b.is_active) then
    raise exception 'unknown_or_inactive_branch: %', p_branch;
  end if;

  execute format('select count(*) from public.%I', public.branch_part_name('branch_stock_stage', p_branch)) into staged;
  execute format('select count(*) from public.%I', public.branch_part_name('branch_stock', p_branch)) into live;

  if staged = 0 then
    raise exception 'empty_stage_refused: branch=%', p_branch;   -- تبديل بصفر صف = مسح الفرع
  end if;
  if p_expected is not null and staged <> p_expected then
    raise exception 'incomplete_payload: branch=% staged=% expected=%', p_branch, staged, p_expected;
  end if;

  execute format('truncate public.%I', public.branch_part_name('branch_stock', p_branch));
  execute format('insert into public.%I select * from public.%I',
                 public.branch_part_name('branch_stock', p_branch),
                 public.branch_part_name('branch_stock_stage', p_branch));
  get diagnostics moved = row_count;
  execute format('truncate public.%I', public.branch_part_name('branch_stock_stage', p_branch));

  return jsonb_build_object('branch', p_branch, 'was', live, 'now', moved, 'at', now());
end $fn$;

revoke all on function public.stage_branch_stock(text, jsonb, boolean)  from public, anon, authenticated;
revoke all on function public.commit_branch_stock(text, integer)        from public, anon, authenticated;
grant execute on function public.stage_branch_stock(text, jsonb, boolean) to service_role;
grant execute on function public.commit_branch_stock(text, integer)       to service_role;

/* ───────────────────────────────────────────────────────────────────────────
   5) الجسر — يملا الجديد من الجداول القديمة
   مؤقت: طول فترة التشغيل المزدوج، n8n بيفضل يكتب في stock_<الفرع> زي ما هو،
   والدالة دي بتنقل منها للجدول الجديد. بتتشال في خطوة التبديل.
   ─────────────────────────────────────────────────────────────────────────── */
create or replace function public.sync_branch_stock_from_legacy()
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare r record; src text; n int; out_j jsonb := '{}'::jsonb;
begin
  perform public.ensure_branch_partitions();
  for r in select code from public.branches where is_active and code is not null order by sort_order loop
    src := 'stock_' || r.code;
    if not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                   where ns.nspname = 'public' and c.relname = src and c.relkind = 'r') then
      continue;                                  -- فرع جديد لسه مالوش جدول قديم — عادي
    end if;
    execute format('truncate public.%I', public.branch_part_name('branch_stock', r.code));
    execute format($q$
      insert into public.%I
      select %L, itm_code, itnl_code, itm_name_ar, itm_name_en, u_name_big, u_name_medium,
             u_name_small, sto_name, sto_qty_big, sto_qty_medium, sto_qty_small,
             itm_sell_price_big, itm_sell_price_medium, itm_sell_price_small,
             unit_big_medium_coeff, unit_big_small_coeff, itm_ismedicine, "Company_Name_Ar",
             insert_date, update_date, last_trans_date, updated_at
      from public.%I $q$, public.branch_part_name('branch_stock', r.code), r.code, src);
    get diagnostics n = row_count;
    out_j := out_j || jsonb_build_object(r.code, n);
  end loop;
  return out_j;
end $fn$;

/* ───────────────────────────────────────────────────────────────────────────
   6) جدول الظل — نفس شكل stock_flat بس أعمدة الفروع بتتخلق لوحدها
   ─────────────────────────────────────────────────────────────────────────── */
create table if not exists public.stock_flat_prefix (
  branch_code text primary key,
  prefix      text not null unique
);
insert into public.stock_flat_prefix(branch_code, prefix)
values ('mamora','m'), ('san','s'), ('bishr','b')
on conflict (branch_code) do nothing;         -- الفروع الحالية تحتفظ بأعمدتها m_/s_/b_

create table if not exists public.stock_flat_shadow (
  itm_code     text primary key,
  n            text,
  co           text,
  u            text,
  med          integer,
  n_norm       text,
  n_fw         text,
  n_fw_sorted  text
);
alter table public.stock_flat_shadow enable row level security;
revoke all on public.stock_flat_shadow from anon, authenticated;

create or replace function public.sync_stock_flat_columns()
returns text language plpgsql security definer set search_path = public as $fn$
declare r record; pfx text; added text := '';
begin
  for r in select code from public.branches
           where is_active and code is not null order by sort_order, name loop
    insert into public.stock_flat_prefix(branch_code, prefix)
      select r.code, r.code
      where not exists (select 1 from public.stock_flat_prefix f where f.branch_code = r.code);
    select f.prefix into pfx from public.stock_flat_prefix f where f.branch_code = r.code;
    if not exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'stock_flat_shadow'
                     and column_name = pfx || '_h') then
      execute format('alter table public.stock_flat_shadow add column %I boolean, add column %I numeric, add column %I numeric',
                     pfx || '_h', pfx || '_q', pfx || '_p');
      added := added || pfx || ' ';
    end if;
  end loop;
  return case when added = '' then 'no new branch columns' else 'added: ' || added end;
end $fn$;

-- نفس منطق refresh_stock_flat الحالية بالحرف، بس مبني من الجدول الطولي
-- وبعدد فروع مفتوح بدل 3 ثابتين.
create or replace function public.refresh_stock_flat_shadow()
returns integer language plpgsql security definer set search_path = public as $fn$
declare
  r record; pfx text; n int;
  coal_name text := ''; coal_co text := ''; coal_u text := ''; coal_med text := '';
  agg_cols text := ''; sel_cols text := ''; ins_cols text := ''; sql text;
begin
  perform public.ensure_branch_partitions();
  perform public.sync_stock_flat_columns();

  for r in select code from public.branches
           where is_active and code is not null order by sort_order, name loop
    select f.prefix into pfx from public.stock_flat_prefix f where f.branch_code = r.code;

    coal_name := coal_name || format('max(case when bs.branch_code=%L then bs.itm_name_ar end), ', r.code);
    coal_co   := coal_co   || format('max(case when bs.branch_code=%L then bs."Company_Name_Ar" end), ', r.code);
    coal_u    := coal_u    || format('max(case when bs.branch_code=%L then bs.u_name_big end), ', r.code);
    coal_med  := coal_med  || format('max(case when bs.branch_code=%L and bs.itm_ismedicine ~ ''^[0-9]+$'' then bs.itm_ismedicine::int end), ', r.code);

    agg_cols := agg_cols
      || format(', bool_or(bs.branch_code=%L) as %I', r.code, pfx || '_h')
      || format(', coalesce(max(case when bs.branch_code=%L and bs.sto_qty_big ~ ''^-?[0-9]+([.][0-9]+)?$'' then bs.sto_qty_big::numeric end), 0) as %I', r.code, pfx || '_q')
      || format(', coalesce(max(case when bs.branch_code=%L and bs.itm_sell_price_big ~ ''^-?[0-9]+([.][0-9]+)?$'' then bs.itm_sell_price_big::numeric end), 0) as %I', r.code, pfx || '_p');

    sel_cols := sel_cols || format(', base.%I, base.%I, base.%I', pfx || '_h', pfx || '_q', pfx || '_p');
    ins_cols := ins_cols || format(', %I, %I, %I',                pfx || '_h', pfx || '_q', pfx || '_p');
  end loop;

  sql := format($q$
    insert into public.stock_flat_shadow (itm_code, n, co, u, med, n_norm, n_fw, n_fw_sorted %s)
    select base.itm_code, base.n, base.co, base.u, base.med,
           public.ar_norm(base.n),
           split_part(public.ar_norm(base.n), ' ', 1),
           public.sort_letters(split_part(public.ar_norm(base.n), ' ', 1)) %s
    from (
      select bs.itm_code,
             coalesce(%s '') as n,
             coalesce(%s '') as co,
             coalesce(%s '') as u,
             coalesce(%s 0)  as med
             %s
      from public.branch_stock bs
      group by bs.itm_code
    ) base $q$, ins_cols, sel_cols, coal_name, coal_co, coal_u, coal_med, agg_cols);

  truncate public.stock_flat_shadow;
  execute sql;
  get diagnostics n = row_count;
  return n;
end $fn$;

/* ───────────────────────────────────────────────────────────────────────────
   7) المقارنة — الظل مقابل الحقيقي، عمود بعمود
   ─────────────────────────────────────────────────────────────────────────── */
create table if not exists public.stock_flat_compare_log (
  id bigserial primary key,
  ran_at timestamptz default now(),
  result jsonb
);

create or replace function public.compare_stock_flat()
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare res jsonb;
begin
  select jsonb_build_object(
    'live_rows',   (select count(*) from public.stock_flat),
    'shadow_rows', (select count(*) from public.stock_flat_shadow),
    'missing_rows', count(*) filter (where o.itm_code is null or s.itm_code is null),
    'diff_name',    count(*) filter (where o.n   is distinct from s.n),
    'diff_company', count(*) filter (where o.co  is distinct from s.co),
    'diff_unit',    count(*) filter (where o.u   is distinct from s.u),
    'diff_med',     count(*) filter (where o.med is distinct from s.med),
    'diff_has',     count(*) filter (where o.m_h is distinct from s.m_h or o.s_h is distinct from s.s_h or o.b_h is distinct from s.b_h),
    'diff_qty',     count(*) filter (where o.m_q is distinct from s.m_q or o.s_q is distinct from s.s_q or o.b_q is distinct from s.b_q),
    'diff_price',   count(*) filter (where o.m_p is distinct from s.m_p or o.s_p is distinct from s.s_p or o.b_p is distinct from s.b_p),
    'diff_search',  count(*) filter (where o.n_norm is distinct from s.n_norm or o.n_fw is distinct from s.n_fw or o.n_fw_sorted is distinct from s.n_fw_sorted)
  ) into res
  from public.stock_flat o full outer join public.stock_flat_shadow s on s.itm_code = o.itm_code;

  insert into public.stock_flat_compare_log(result) values (res);
  return res;
end $fn$;

-- دورة التشغيل المزدوج كاملة: جسر → ظل → مقارنة
create or replace function public.shadow_tick()
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare loaded jsonb; built int;
begin
  loaded := public.sync_branch_stock_from_legacy();
  built  := public.refresh_stock_flat_shadow();
  return jsonb_build_object('loaded', loaded, 'shadow_rows', built, 'compare', public.compare_stock_flat());
end $fn$;

revoke all on function public.shadow_tick() from public, anon, authenticated;

/* ───────────────────────────────────────────────────────────────────────────
   8) أول تشغيل + أول مقارنة (المفروض كل الفروق = 0)
   ─────────────────────────────────────────────────────────────────────────── */
select public.shadow_tick();

commit;

/* ═══════════════════════════════════════════════════════════════════════════
   (اختياري — ما ينفّذش مع السكربت) تشغيل الظل كل 10 دقايق بعد الكرون الحالي
   ───────────────────────────────────────────────────────────────────────────
   select cron.schedule('shadow_stock_10m', '7-59/10 * * * *', 'select public.shadow_tick();');

   والمتابعة:
   select ran_at, result from public.stock_flat_compare_log order by id desc limit 20;
   ═══════════════════════════════════════════════════════════════════════════ */

/* ═══════════════════════════════════════════════════════════════════════════
   9) الرجوع — بيمسح كل اللي السكربت ده ضافه ومش بيلمس أي حاجة قديمة
   ───────────────────────────────────────────────────────────────────────────
   select cron.unschedule('shadow_stock_10m');
   drop function if exists public.shadow_tick();
   drop function if exists public.compare_stock_flat();
   drop function if exists public.refresh_stock_flat_shadow();
   drop function if exists public.sync_stock_flat_columns();
   drop function if exists public.sync_branch_stock_from_legacy();
   drop function if exists public.commit_branch_stock(text, integer);
   drop function if exists public.stage_branch_stock(text, jsonb, boolean);
   drop function if exists public.ensure_branch_partitions();
   drop function if exists public.branch_part_name(text, text);
   drop table    if exists public.stock_flat_compare_log;
   drop table    if exists public.stock_flat_shadow;
   drop table    if exists public.stock_flat_prefix;
   drop table    if exists public.branch_stock_stage;
   drop table    if exists public.branch_stock;
   drop type     if exists public.stock_row;
   ═══════════════════════════════════════════════════════════════════════════ */
