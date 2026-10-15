/* ═══════════════════════════════════════════════════════════════════
   الاستثناء من نفس قايمة «شركاتي» — قايمة واحدة لشاشتين
   ═══════════════════════════════════════════════════════════════════
   migrate_145 عمل قايمة منفصلة (`excluded_companies`). المالك صحّح:
   المصدر لازم يكون **نفس** `pinned_companies` بتاعة شاشة الكوزمو —
   الشركة اللي بتتطلب لوحدها هي هي اللي تتشال من طلبيات الأدوية.
   الفرق في المعنى بس:
     • الكوزمو  → المعلَّم هو اللي **يظهر**
     • الأدوية  → المعلَّم هو اللي **يتشال**

   مكان واحد تتحكم منه، ومستحيل الاتنين يتعارضوا.

   ── ليه تريجر مش نداء جوّه الدالة ───────────────────────────────
   شاشة الكوزمو بتكتب في `pinned_companies` **مباشرة** بـPostgREST
   (POST/DELETE) — مش عبر أي دالة. فلو حطيت تعليم العمود جوّه RPC
   بتاع شاشة الأدوية بس، أي تعديل من الكوزمو كان هيفضل مش واصل
   والأرقام تكدب لحد أول إعادة بناء. التريجر على الجدول بيمسك أي
   كاتب مهما كان مصدره.

   statement-level مش row-level: الحفظ بيبعت صفوف كتير في نداء واحد،
   وتعليم العمود update واحد على الجدول كله — مالوش لازمة يتكرر لكل صف.

   ── التنضيف ─────────────────────────────────────────────────────
   `excluded_companies` و`set_excluded_companies` اتشالوا — جدول
   ميّت بيورّث انحراف.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 0) العمود (اتعمل في migrate_145) — تأمين لو الترتيب اختلف ──── */
alter table public.purchase_orders_flat
  add column if not exists excluded boolean;

create index if not exists purchase_orders_flat_excl_idx
  on public.purchase_orders_flat (branch, excluded);

/* ── 1) تعليم العمود من pinned_companies ───────────────────────── */
create or replace function public.apply_excluded_companies()
returns integer language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.purchase_orders_flat p
     set excluded = exists (select 1 from public.pinned_companies e
                             where e.company = p.company)
   where coalesce(p.excluded, false)
         <> exists (select 1 from public.pinned_companies e
                     where e.company = p.company);
  get diagnostics n = row_count;
  return n;
end
$fn$;

revoke all on function public.apply_excluded_companies() from public, anon;
grant execute on function public.apply_excluded_companies() to authenticated, service_role;

/* ── 2) أي كتابة في القايمة تعلّم العمود فورًا ──────────────────── */
create or replace function public.trg_pinned_companies_apply()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  perform public.apply_excluded_companies();
  return null;
end
$fn$;

drop trigger if exists trg_pinned_apply on public.pinned_companies;
create trigger trg_pinned_apply
  after insert or update or delete on public.pinned_companies
  for each statement execute function public.trg_pinned_companies_apply();

/* ── 3) الكتابة من شاشة الأدوية ────────────────────────────────── */
drop function if exists public.set_excluded_companies(text[]);

/* ⚠️ من غير `require_app_role` بقصد: **نفس** القايمة دي شاشة الكوزمو
   بتكتب فيها مباشرة بـPostgREST من غير أي حارس، والشاشتين مفتوحتين
   لنفس الـ9 أدوار. فحارس هنا كان هيمنع دور يقدر يعمل نفس الحاجة من
   الشاشة التانية — احتكاك من غير حماية. الدالة محجوبة عن anon
   بالـgrant، فمحدش بره الحسابات الداخلة يقدر ينادیها.
   قفل القايمة فعليًا = قرار منفصل لازم يتاخد على الجدول نفسه. */
create or replace function public.set_pinned_companies(p_list text[])
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_n int;
begin
  delete from public.pinned_companies
   where company <> all (coalesce(p_list, array[]::text[]));

  /* الترتيب محفوظ زي ما الشاشة بعتته — شريط الكوزمو بيقرا sort_order */
  insert into public.pinned_companies (company, sort_order, updated_at)
  select x, i - 1, now()
    from unnest(coalesce(p_list, array[]::text[])) with ordinality t(x, i)
   where nullif(btrim(x), '') is not null
  on conflict (company) do update
     set sort_order = excluded.sort_order, updated_at = now();

  select count(*) into v_n from public.pinned_companies;
  return jsonb_build_object('companies', v_n,
                            'rows', (select count(*) from public.purchase_orders_flat where excluded));
end
$fn$;

revoke all on function public.set_pinned_companies(text[]) from public, anon;
grant execute on function public.set_pinned_companies(text[]) to authenticated, service_role;

/* ── 4) الشركات بعددها في الفرع (لمودال الاختيار) ──────────────── */
create or replace function public.get_purchase_company_counts(p_branch text)
returns table (company text, n integer)
language sql
stable
as $fn$
  select coalesce(nullif(btrim(p.company), ''), 'بدون شركة') company, count(*)::int n
    from public.purchase_orders_flat p
   where p.branch = p_branch
   group by 1
  union
  /* شركة معلَّمة مالهاش أصناف أدوية في الفرع ده لازم تفضل ظاهرة عشان
     تقدر تشيلها — غير كده بتتقفل بره من غير طريقة رجوع. */
  select e.company, 0
    from public.pinned_companies e
   where not exists (select 1 from public.purchase_orders_flat p
                      where p.branch = p_branch
                        and coalesce(nullif(btrim(p.company), ''), 'بدون شركة') = e.company)
   order by 2 desc, 1
$fn$;

revoke all on function public.get_purchase_company_counts(text) from public, anon;
grant execute on function public.get_purchase_company_counts(text) to authenticated, service_role;

/* ── 5) البصمة تقرا القايمة الصح ───────────────────────────────── */
create or replace function public.refresh_purchase_orders(p_force boolean default false)
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
declare
  n int; v_cols text; v_fp text; v_prev text;
begin
  if coalesce(current_setting('request.jwt.claims', true),'') <> '' then
    perform public.require_app_role(array['admin','manager','pharmacist']);
  end if;

  select coalesce((select m.src_max::text from public.stock_flat_meta m where m.id = 1), '-')
      || '|' || coalesce((select max(c.refreshed_at)::text from public.consumption_flat c), '-')
      || '|' || coalesce((select max(b.updated_at)::text from public.branch_calc_settings b), '-')
      || '|' || (select count(*)::text from public.branch_calc_settings)
      || '|' || coalesce((select max(p.updated_at)::text from public.best_purchase_by_code p), '-')
      || '|' || coalesce((select md5(ps::text) from public.purchase_settings ps where ps.id = 1), '-')
      || '|' || coalesce((select max(e.synced_at)::text from public.item_expiry e), '-')
      || '|' || (select count(*)::text from public.item_expiry)
      /* قايمة الشركات المعلَّمة = المستثناة هنا */
      || '|' || coalesce((select max(x.updated_at)::text from public.pinned_companies x), '-')
      || '|' || (select count(*)::text from public.pinned_companies)
      || '|' || current_date::text
    into v_fp;

  select f.src_fp into v_prev from public.purchase_orders_flat_meta f where f.id = 1;

  if not coalesce(p_force, false) and v_prev is not null and v_fp = v_prev then
    return (select count(*)::int from public.purchase_orders_flat);
  end if;

  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'purchase_orders_flat' and column_name <> 'id';

  truncate purchase_orders_flat;
  execute 'insert into purchase_orders_flat (' || v_cols || ')'
       || ' select ' || v_cols || ' from public.get_purchase_orders()';
  get diagnostics n = row_count;

  update purchase_orders_flat p
     set best_pur_store = bpc.price_store
    from best_purchase_by_code bpc
   where bpc.itm_code = p.itm_code;

  /* الـtruncate بيمسح العمود المحسوب، فلازم يترسم تاني هنا */
  perform public.apply_excluded_companies();

  update public.purchase_orders_flat_meta
     set src_fp = v_fp, refreshed_at = now()
   where id = 1;

  return n;
end
$fn$;

revoke all on function public.refresh_purchase_orders(boolean) from public, anon;
grant execute on function public.refresh_purchase_orders(boolean) to authenticated, service_role;

/* ── 6) جدول ميّت ───────────────────────────────────────────────── */
drop table if exists public.excluded_companies;

select public.apply_excluded_companies();
