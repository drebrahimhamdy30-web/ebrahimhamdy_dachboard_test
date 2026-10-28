/* ═══════════════════════════════════════════════════════════════════
   شاشة «الصلاحيات القريبة» — expiry.html
   ═══════════════════════════════════════════════════════════════════
   الهدف (المالك 2026-10-28): بعض الشركات بتقبل مرتجع المنتج قبل
   انتهائه بمدة (امتنان ٤ شهور مثلًا). محتاجين نشوف الدفعات القريبة
   عشان (١) نرجّعها للشركة، و(٢) نبطّل نوفّر الصنف إلا بطلب، و(٣)
   نبصّ عليها إحنا بنطلب.

   ── قرارات مأخوذة قبل البناء ────────────────────────────────────
   • **المصدر**: `item_expiry` — مخزون eplus بالدفعات (`itm_qty > 0`)،
     مش فواتير الشراء. الفواتير مرفوضة كمصدر لأن التاريخ ممكن يتدخّل
     غلط ويتعدّل بعدين (قرار المالك).
   • **الوحدة**: الكمية **بالشريط** زي ما eplus بيعدّ — بدون أي تحويل.
     ومحصّلة كده إن المعدل والرصيد (بالعلبة) اتشالوا من العرض خالص،
     عشان مايبقاش في الجدول وحدتين.
   • **«مباع»**: معدل الصنف في **فرعه** أكبر من صفر. 290 صنف من 598
     مش موجودين في `consumption_flat` أصلًا = عمرهم ما اتباعوا.
   • **«له رصيد»**: `last_seen` = آخر يوم مزامنة **لفرعه**
     (migrate_165). ده الافتراضي في العرض، والجدول نفسه بيراكم بلا حذف.
   • **السياسة**: جدول يكتبه المالك، والاسم يطابق **شركة الصنف** أو
     **مورّد اشترينا منه الصنف ده في الفرع ده**. ليه الاتنين: عمود
     الشركة في eplus رقم تصنيف في 59% من الأصناف («2» لوحدها 8,680
     صنف)، فالمطابقة بالشركة وحدها كانت هتغطّي 136 صنف من 598.
     ⚠️ المطابقة بالمورّد على مستوى **الصنف** مش الدفعة — ربط الدفعة
     بفاتورتها بيعتمد على تطابق شهر الصلاحية، ونجح في 33% بس وبيقع
     لو التاريخ اتعدّل.

   ── اللي الشاشة بتعمله ──────────────────────────────────────────
   `get_expiry_watch` بترجّع صفحة من الدفعات + إجماليات محسوبة على
   **كل** المفلتر (مش الصفحة)، و`set_expiry_action` بتسجّل القرار.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── ١) سياسة المرتجع ───────────────────────────────────────────── */
create table if not exists public.expiry_return_policy (
  party         text primary key,
  months_before int  not null default 4 check (months_before between 1 and 24),
  active        boolean not null default true,
  note          text,
  updated_by    text,
  updated_at    timestamptz not null default now()
);
comment on table public.expiry_return_policy is
  'شركات/موردين بيقبلوا مرتجع قبل الانتهاء بمدة. الاسم بيطابق شركة الصنف أو مورّد اشترينا منه الصنف في الفرع.';

/* ── ٢) قرار على كل دفعة ────────────────────────────────────────── */
create table if not exists public.expiry_actions (
  branch      text not null,
  itm_code    text not null,
  exp_date    date not null,
  action      text not null check (action in ('return','transfer','discount','stop','done')),
  note        text,
  decided_by  text,
  decided_at  timestamptz not null default now(),
  primary key (branch, itm_code, exp_date)
);
comment on table public.expiry_actions is
  'قرار الدفعة: return يترجع للشركة · transfer يتحوّل لفرع · discount يتباع بخصم · stop مايتطلبش تاني · done اتحل.';

/* ── ٣) القائمة ─────────────────────────────────────────────────── */
create or replace function public.get_expiry_watch(
  p_branch      text    default null,
  p_months      int     default 4,
  p_company     text    default null,
  p_sold        text    default null,     -- 'yes' | 'no' | null
  p_policy_only boolean default false,
  p_q           text    default null,
  p_live_only   boolean default true,
  p_action      text    default null,     -- 'none' | قيمة من expiry_actions | null
  p_page        int     default 1,
  p_size        int     default 50
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_scope  text := public.purchase_branch_scope(p_branch, 'expiry');
  v_months int  := greatest(1, least(coalesce(p_months, 4), 24));
  v_size   int  := greatest(1, least(coalesce(p_size, 50), 200));
  v_page   int  := greatest(1, coalesce(p_page, 1));
  v_q      text := nullif(btrim(coalesce(p_q, '')), '');
  v_out    jsonb;
begin
  with
  /* آخر يوم مزامنة لكل فرع — «له رصيد» تتقاس عليه */
  live as (
    select branch, max(last_seen) d from item_expiry group by branch
  ),
  base as (
    select e.branch, e.itm_code, e.exp_date, e.qty, e.last_seen, e.first_seen,
           sf.n  as itm_name,
           sf.co as company,
           sf.u  as unit,
           case e.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san
                when 'bishr' then cf.av_bishr when 'seyouf' then cf.av_seyouf end as rate,
           (e.exp_date - current_date) as days_left,
           (e.last_seen = lv.d)        as is_live
      from item_expiry e
      join live lv on lv.branch = e.branch
      left join stock_flat sf       on sf.itm_code = e.itm_code
      left join consumption_flat cf on cf.code     = e.itm_code
     where e.exp_date < current_date + (v_months || ' months')::interval
       and (v_scope is null or e.branch = v_scope)
  ),
  tagged as (
    select b.*,
           coalesce(b.rate, 0) > 0 as sold,
           /* السياسة: بالشركة أو بمورّد اشترينا منه الصنف في الفرع */
           (select max(p.months_before) from expiry_return_policy p
             where p.active
               and ( p.party = b.company
                  or exists (select 1
                               from purchase_invoice_items i
                               join purchase_invoices h
                                 on h.branch = i.branch and h.pth_id = i.pth_id
                              where i.itm_code = b.itm_code
                                and i.branch   = b.branch
                                and h.ven_name_ar = p.party) )
           ) as policy_months,
           a.action, a.note as action_note, a.decided_by, a.decided_at
      from base b
      left join expiry_actions a
        on a.branch = b.branch and a.itm_code = b.itm_code and a.exp_date = b.exp_date
  ),
  filtered as (
    select * from tagged t
     where (not p_live_only or t.is_live)
       and (p_company is null or t.company = p_company)
       and (p_sold is null
            or (p_sold = 'yes' and t.sold)
            or (p_sold = 'no'  and not t.sold))
       and (not p_policy_only or t.policy_months is not null)
       and (p_action is null
            or (p_action = 'none' and t.action is null)
            or t.action = p_action)
       and (v_q is null
            or t.itm_code ilike '%' || v_q || '%'
            or coalesce(t.itm_name, '') ilike '%' || v_q || '%')
  )
  select jsonb_build_object(
    'total',    (select count(*) from filtered),
    'pages',    (select greatest(1, ceil(count(*)::numeric / v_size)::int) from filtered),
    'page',     v_page,
    'size',     v_size,
    'scope',    v_scope,
    'sums', (select jsonb_build_object(
               'batches', count(*),
               'items',   count(distinct itm_code),
               'qty',     coalesce(sum(qty), 0),
               'unsold',  count(*) filter (where not sold),
               'unknown', count(*) filter (where itm_name is null))
               from filtered),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'branch',       f.branch,
               'itm_code',     f.itm_code,
               'itm_name',     coalesce(f.itm_name, '—'),
               'company',      coalesce(f.company, '—'),
               /* ⚠️ كود مش موجود في stock_flat = الاسم والشركة مجهولين.
                  السبب: مزامنة الصلاحيات بتاخد Item_Class_Store.itm_id
                  كأنه كودنا، وده صحيح لأغلب الأصناف ومش صحيح لكلها.
                  الشاشة بتعلّم الصف بدل ما تعرض «—» من غير تفسير. */
               'known',        (f.itm_name is not null),
               'unit',         f.unit,
               'exp_date',     to_char(f.exp_date, 'MM-YYYY'),
               'days_left',    f.days_left,
               'qty',          f.qty,
               'sold',         f.sold,
               'policy_months', f.policy_months,
               'is_live',      f.is_live,
               'last_seen',    f.last_seen,
               'action',       f.action,
               'action_note',  f.action_note,
               'decided_by',   f.decided_by)
             order by f.days_left asc, f.qty desc, f.itm_code)
        from (select * from filtered
               order by days_left asc, qty desc, itm_code
               offset (v_page - 1) * v_size limit v_size) f), '[]'::jsonb)
  ) into v_out;

  return v_out;
end$fn$;

/* ── ٤) تسجيل القرار ────────────────────────────────────────────── */
create or replace function public.set_expiry_action(
  p_branch text, p_itm_code text, p_exp_date date,
  p_action text, p_note text default null
) returns jsonb
language plpgsql volatile security definer set search_path to 'public' as $fn$
declare v_by text; v_scope text;
begin
  perform public.require_page_edit('expiry');
  /* الفرع بيتفرض من الحارس — اللي بيشوف فرعه مايسجّلش على فرع تاني */
  v_scope := public.purchase_branch_scope(p_branch, 'expiry');
  if v_scope is not null and v_scope <> p_branch then
    raise exception 'غير مصرّح بالتسجيل على فرع %', p_branch using errcode = '42501';
  end if;

  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'full_name',
                   nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'name',
                   public.jwt_app_role(), 'غير معروف');

  if p_action is null or p_action = '' then
    delete from expiry_actions
     where branch = p_branch and itm_code = p_itm_code and exp_date = p_exp_date;
    return jsonb_build_object('ok', true, 'action', null);
  end if;

  insert into expiry_actions(branch, itm_code, exp_date, action, note, decided_by)
  values (p_branch, p_itm_code, p_exp_date, p_action, nullif(btrim(coalesce(p_note,'')),''), v_by)
  on conflict (branch, itm_code, exp_date) do update
    set action = excluded.action, note = excluded.note,
        decided_by = excluded.decided_by, decided_at = now();

  return jsonb_build_object('ok', true, 'action', p_action, 'by', v_by);
end$fn$;

/* ── ٥) السياسة: قراءة وكتابة ───────────────────────────────────── */
create or replace function public.get_expiry_policy()
returns setof public.expiry_return_policy
language sql stable security definer set search_path to 'public' as $fn$
  select * from expiry_return_policy order by active desc, party;
$fn$;

create or replace function public.set_expiry_policy(
  p_party text, p_months int default 4, p_active boolean default true, p_note text default null
) returns jsonb
language plpgsql volatile security definer set search_path to 'public' as $fn$
declare v_by text; v_party text := nullif(btrim(coalesce(p_party,'')),'');
begin
  perform public.require_page_edit('expiry');
  if v_party is null then
    raise exception 'لازم تكتب اسم الجهة' using errcode = '22023';
  end if;
  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'full_name',
                   public.jwt_app_role(), 'غير معروف');

  insert into expiry_return_policy(party, months_before, active, note, updated_by)
  values (v_party, coalesce(p_months,4), coalesce(p_active,true),
          nullif(btrim(coalesce(p_note,'')),''), v_by)
  on conflict (party) do update
    set months_before = excluded.months_before, active = excluded.active,
        note = excluded.note, updated_by = excluded.updated_by, updated_at = now();

  return jsonb_build_object('ok', true, 'party', v_party);
end$fn$;

create or replace function public.del_expiry_policy(p_party text)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $fn$
begin
  perform public.require_page_edit('expiry');
  delete from expiry_return_policy where party = p_party;
  return jsonb_build_object('ok', true);
end$fn$;

/* ── ٦) قائمة الشركات اللي عندها دفعات قريبة (لفلتر الشاشة) ────── */
create or replace function public.get_expiry_companies(p_months int default 4)
returns table (company text, batches bigint)
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(sf.co, '—') company, count(*) batches
    from item_expiry e
    join (select branch, max(last_seen) d from item_expiry group by branch) lv
      on lv.branch = e.branch and e.last_seen = lv.d
    left join stock_flat sf on sf.itm_code = e.itm_code
   where e.exp_date < current_date
         + (greatest(1, least(coalesce(p_months,4), 24)) || ' months')::interval
     and (public.purchase_branch_scope(null, 'expiry') is null
          or e.branch = public.purchase_branch_scope(null, 'expiry'))
   group by 1
   order by 2 desc, 1;
$fn$;

/* ── ٧) الصلاحيات ───────────────────────────────────────────────── */
grant select on public.expiry_return_policy to authenticated;
grant select on public.expiry_actions       to authenticated;

do $$
declare r record;
begin
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('get_expiry_watch','set_expiry_action','get_expiry_policy',
                         'set_expiry_policy','del_expiry_policy','get_expiry_companies')
  loop
    execute format('revoke all on function public.%I(%s) from public, anon', r.proname, r.args);
    execute format('grant execute on function public.%I(%s) to authenticated', r.proname, r.args);
  end loop;
end $$;

/* ── ٨) تسجيل الشاشة ────────────────────────────────────────────── */
insert into public.app_pages (key, file, title, section, sort_order, is_active)
values ('expiry', 'expiry.html', 'الصلاحيات القريبة', 'المشتريات والموردين', 424, true)
on conflict (key) do update
  set file = excluded.file, title = excluded.title,
      section = excluded.section, sort_order = excluded.sort_order, is_active = true;

/* ⚠️ صف بلا can_view = شاشة مخفية بصمت — register_page_roles بتضمن true */
select public.register_page_roles(
  'expiry',
  array['admin','manager','pharmacist','reviewer','employee'],   -- عرض
  array['admin','manager','pharmacist','reviewer'],              -- تعديل
  array['admin','pharmacist','reviewer']                         -- كل الفروع
);

notify pgrst, 'reload schema';
