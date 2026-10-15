/* ═══════════════════════════════════════════════════════════════════
   شركات مستثناة من طلبيات الأدوية
   ═══════════════════════════════════════════════════════════════════
   ── الفكرة (قرار المالك) ─────────────────────────────────────────
   الشركات اللي بقينا نطلبها لوحدها (من شاشة الكوزمو) مالهاش لازمة في
   «طلبيات الأدوية» — بتزحم القايمة وتطلّع أرقام شراء لحاجة اتطلبت
   أصلًا. فبقى فيه قايمة اختيار بنفس شكل «شركاتي» في الكوزمو، بس
   **بالعكس**: اللي متعلّم عليه هنا = مستثنى.

   قايمة منفصلة عن `pinned_companies` بقرار المالك — مش ربط تلقائي.

   ── ليه عمود مش فلتر في الرابط ──────────────────────────────────
   أول فكرة كانت `company=not.in.(…)` من الشاشة. ده كان بيقع: اسم
   الشركة العربي بيتحوّل لـ9 حروف لكل حرف في الـURL، فـ40 شركة =
   ~5,000 حرف في كل نداء، ومعاها الفلاتر التانية الرابط بيتقص.
   وكمان `not.in` بيلغي استعمال الفهرس.

   فالاستثناء بقى **عمود محسوب** في `purchase_orders_flat`:
     • `set_excluded_companies()` بتكتب القايمة وتعلّم العمود في نداء
       واحد — فمفيش لحظة القايمة فيها اتغيّرت والأرقام لسه قديمة.
     • `refresh_purchase_orders` بتعيد تعليمه بعد كل إعادة بناء،
       لأنها بتعمل `truncate` فالعمود بيروح.
     • والقايمة دخلت **بصمة المصادر** — من غير كده تعديل القايمة
       مايأثرش في الأرقام خالص (نفس الفخ بتاع migrate_140).

   الشاشة بتفلتر بـ`excluded=not.is.true`، وفيه مفتاح «إظهار المستثنى»
   بيرجّعهم للعرض من غير ما يمسح القايمة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.excluded_companies (
  company    text primary key,
  updated_at timestamptz not null default now(),
  updated_by text
);

comment on table public.excluded_companies is
  'شركات مستبعدة من شاشة طلبيات الأدوية (بتتطلب لوحدها). التعديل عبر set_excluded_companies() بس.';

revoke all on table public.excluded_companies from public, anon;
grant select on table public.excluded_companies to authenticated;
grant select, insert, update, delete on table public.excluded_companies to service_role;

/* العمود nullable بقصد: get_purchase_orders بتحط null في أي عمود
   مش في خريطتها، والـ`not null default false` كان هيوقّع الإدخال. */
alter table public.purchase_orders_flat
  add column if not exists excluded boolean;

comment on column public.purchase_orders_flat.excluded is
  'true = شركة الصنف في excluded_companies. محسوب — ممنوع التعديل اليدوي.';

create index if not exists purchase_orders_flat_excl_idx
  on public.purchase_orders_flat (branch, excluded);

/* ── تعليم العمود ───────────────────────────────────────────────── */
create or replace function public.apply_excluded_companies()
returns integer language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  /* update واحد على الجدول كله، وبيلمس الصفوف اللي علامتها اتغيّرت بس */
  update public.purchase_orders_flat p
     set excluded = exists (select 1 from public.excluded_companies e
                             where e.company = p.company)
   where coalesce(p.excluded, false)
         <> exists (select 1 from public.excluded_companies e
                     where e.company = p.company);
  get diagnostics n = row_count;
  return n;
end
$fn$;

revoke all on function public.apply_excluded_companies() from public, anon;
grant execute on function public.apply_excluded_companies() to authenticated, service_role;

/* ── الكتابة ────────────────────────────────────────────────────── */
create or replace function public.set_excluded_companies(p_list text[])
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_n int; v_rows int;
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);

  delete from public.excluded_companies
   where company <> all (coalesce(p_list, array[]::text[]));

  insert into public.excluded_companies (company, updated_at, updated_by)
  select distinct x, now(), public.jwt_app_role()
    from unnest(coalesce(p_list, array[]::text[])) x
   where nullif(btrim(x), '') is not null
  on conflict (company) do update
     set updated_at = now(), updated_by = excluded.updated_by;

  select count(*) into v_n from public.excluded_companies;
  v_rows := public.apply_excluded_companies();

  return jsonb_build_object('companies', v_n, 'rows', v_rows);
end
$fn$;

revoke all on function public.set_excluded_companies(text[]) from public, anon;
grant execute on function public.set_excluded_companies(text[]) to authenticated, service_role;

/* ── الشركات بعدد أصنافها في الفرع (لمودال الاختيار) ───────────── */
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
  /* شركة مستثناة مالهاش أصناف في الفرع ده لازم تفضل ظاهرة في المودال
     عشان تقدر تشيلها — غير كده بتتقفل بره من غير طريقة رجوع. */
  select e.company, 0
    from public.excluded_companies e
   where not exists (select 1 from public.purchase_orders_flat p
                      where p.branch = p_branch
                        and coalesce(nullif(btrim(p.company), ''), 'بدون شركة') = e.company)
   order by 2 desc, 1
$fn$;

revoke all on function public.get_purchase_company_counts(text) from public, anon;
grant execute on function public.get_purchase_company_counts(text) to authenticated, service_role;

/* ── البصمة + إعادة التعليم بعد كل بناء ────────────────────────── */
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
      /* قايمة الاستثناء: من غيرها التعديل مايبانش في الأرقام */
      || '|' || coalesce((select max(x.updated_at)::text from public.excluded_companies x), '-')
      || '|' || (select count(*)::text from public.excluded_companies)
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
