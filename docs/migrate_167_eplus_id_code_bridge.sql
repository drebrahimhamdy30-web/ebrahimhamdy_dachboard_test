/* ═══════════════════════════════════════════════════════════════════
   جسر itm_id ↔ كود الصنف — يصلّح الأكواد المجهولة في الصلاحيات
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   كل مزامنة بتقرا eplus بـSQL مباشر بتاخد `itm_id` **كأنه كودنا**:

     تواريخ الصلاحية  →  itm_id AS itm_code
     تغيّرات الأسعار   →  ich_itm_id AS itm_code
     مرتجعات الشراء   →  ibd_itm_id AS itm_id

   وده صحيح لأغلب الأصناف ومش صحيح لكلها. اتأكد على eplus مباشرة
   (2026-10-28): أعمدة الكود والاسم في `Item_Catalog` **فاضية
   تمامًا — صفر من 31,189 صف**، والبيانات مشفّرة في `itm_data`
   بمفتاح مش عندنا. يعني **مفيش طريق SQL** من itm_id للكود المقروء.

   والنتيجة في جدول الصلاحيات: **14,933 دفعة من 38,449 (39%)**
   كودها مش موجود في `stock_flat` — 3,975 كود، 106,832 وحدة، بلا
   اسم ولا شركة.

   ── الدليل ───────────────────────────────────────────────────────
   تصدير «منتهى صلاحية» من eplus (28/10، الأربع فروع، صلاحية
   10/2026→02/2027) قارنّاه بجدولنا:
     • 454 دفعة من 626 بتتطابق بالكود (73%)
     • 172 دفعة في التقرير ومش عندنا — **أكوادها قصيرة** (117 منها
       من 4 خانات) بينما اللي عندنا بس كلها 5 خانات.
     • 154 من الـ172 ليها مقابل عندنا بنفس الفرع والشهر وبنسبة كمية
       صحيحة — يعني **نفس الدفعة برقمين مختلفين**، مش بيانات ناقصة.

   ── الحل ─────────────────────────────────────────────────────────
   `purchase_invoice_items` فيه العمودين مع بعض: `itm_id` (من eplus)
   و`itm_code` (اتعبّى من جسر إكسل المشتريات، migrate_104/105).
   يعني هو **قاموس itm_id ↔ كود** جاهز عندنا من غير ما نلمس eplus.

     14,664 زوج · **14,138 منها قاطع** (كود واحد لكل itm_id)
     7,964 بس منها itm_id = الكود → يعني **6,700 صنف رقمهم الداخلي مختلف**
     **3,755 من 3,975 كود مجهول بيتحلّوا بالجسر (94%)**

   وبتطبيقه على المقارنة مع تقرير eplus: التطابق **454 → 594 من 626
   (73% → 95%)**.

   ⚠️ **الحارس مقدّس**: itm_id له أكتر من كود = **يتستبعد**. «مش
      معروف» أأمن من كود غلط — كود غلط بيوريك اسم صنف تاني خالص.
      راجع [[purchase-code-map-expiry]].

   ── ليه جدول مش استعلام فرعي ────────────────────────────────────
   نفس المشكلة في «تغيّرات الأسعار» و«مرتجعات الشراء»، فالقاموس
   مشترك ويتبني مرة واحدة ويتحدّث مع المشتريات.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.eplus_id_code (
  itm_id     bigint primary key,
  itm_code   text   not null,
  seen       int    not null default 0,
  updated_at timestamptz not null default now()
);
comment on table public.eplus_id_code is
  'قاموس itm_id (الرقم الداخلي في eplus) ↔ كود الصنف عندنا، مبني من purchase_invoice_items. الأكواد المتضاربة مستبعدة بقصد.';

create or replace function public.refresh_eplus_id_code()
returns int language plpgsql security definer set search_path to 'public' as $fn$
declare n int;
begin
  with pairs as (
    select itm_id, itm_code, count(*) seen
      from purchase_invoice_items
     where itm_id is not null
       and itm_code is not null and btrim(itm_code) <> ''
     group by itm_id, itm_code),
  solid as (
    /* ⚠️ كود واحد بس لكل itm_id — المتضارب يتستبعد خالص */
    select itm_id, min(itm_code) itm_code, sum(seen)::int seen
      from pairs group by itm_id having count(*) = 1)
  insert into eplus_id_code (itm_id, itm_code, seen, updated_at)
  select itm_id, itm_code, seen, now() from solid
  on conflict (itm_id) do update
    set itm_code = excluded.itm_code, seen = excluded.seen, updated_at = now();
  get diagnostics n = row_count;

  /* itm_id بقى متضارب بعد فواتير جديدة = يتشال، مانكدبش عليه */
  delete from eplus_id_code d
   where not exists (
     select 1 from purchase_invoice_items i
      where i.itm_id = d.itm_id and i.itm_code = d.itm_code);

  return n;
end$fn$;

select public.refresh_eplus_id_code() as pairs_loaded;

create index if not exists eplus_id_code_code_idx on public.eplus_id_code (itm_code);

/* ── الكود الحقيقي لصف الصلاحيات ────────────────────────────────
   لو الكود موجود في الكتالوج يبقى هو. غير كده نجرّب الجسر. */
create or replace function public.expiry_real_code(p_code text)
returns text language sql stable set search_path to 'public' as $fn$
  select case
    when exists (select 1 from stock_flat s where s.itm_code = p_code) then p_code
    else coalesce((select m.itm_code from eplus_id_code m
                    where m.itm_id::text = p_code), p_code)
  end;
$fn$;
revoke all on function public.expiry_real_code(text) from public, anon;
grant execute on function public.expiry_real_code(text) to authenticated;
grant select on public.eplus_id_code to authenticated;

notify pgrst, 'reload schema';

/* ── get_expiry_watch يقرا الكود عبر الجسر ──────────────────────
   ⚠️ الهوية للقرارات فضلت **الكود الخام** زي ما هو متخزّن في
   item_expiry (`raw_code`)، والكود الحقيقي للعرض بس. لو خلّينا
   القرار على الكود المحلول، أي تغيير في الجسر بكرة كان هيفقد
   القرارات المسجّلة. */
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
  resolved as (
    /* الكود الخام لو موجود في الكتالوج، وإلا الجسر (migrate_167) */
    select e.branch, e.itm_code raw_code, e.exp_date, e.qty, e.last_seen, e.first_seen,
           lv.d as live_day,
           case when s0.itm_code is not null then e.itm_code
                else coalesce(m.itm_code, e.itm_code) end as itm_code
      from item_expiry e
      join live lv on lv.branch = e.branch
      left join stock_flat s0    on s0.itm_code = e.itm_code
      left join eplus_id_code m  on m.itm_id::text = e.itm_code
     where e.exp_date < current_date + (v_months || ' months')::interval
       and (v_scope is null or e.branch = v_scope)
  ),
  base as (
    select r.*,
           sf.n  as itm_name,
           sf.co as company,
           sf.u  as unit,
           case r.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san
                when 'bishr' then cf.av_bishr when 'seyouf' then cf.av_seyouf end as rate,
           (r.exp_date - current_date) as days_left,
           (r.last_seen = r.live_day)  as is_live
      from resolved r
      left join stock_flat sf       on sf.itm_code = r.itm_code
      left join consumption_flat cf on cf.code     = r.itm_code
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
        on a.branch = b.branch and a.itm_code = b.raw_code and a.exp_date = b.exp_date
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
               'raw_code',     f.raw_code,
               'bridged',      (f.itm_code <> f.raw_code),
               'itm_name',     coalesce(f.itm_name, '—'),
               'company',      coalesce(f.company, '—'),
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

notify pgrst, 'reload schema';
