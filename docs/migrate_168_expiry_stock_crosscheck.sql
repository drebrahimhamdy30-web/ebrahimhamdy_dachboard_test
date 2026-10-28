/* ═══════════════════════════════════════════════════════════════════
   الصلاحيات: دفعة رصيد صنفها صفر ماتتعرضش + مزامنة أكتر تكرارًا
   ═══════════════════════════════════════════════════════════════════
   ── الملاحظة (المالك 2026-10-28) ────────────────────────────────
   «69690 ظاهر إن انتهاءه شهر 11 والكمية 2 — وهو أصلًا ملوش رصيد».

   ── الفحص ────────────────────────────────────────────────────────
   قراءة eplus مباشرة للصنف 69690:
     الصيدلية (sto_id 1) · 2026-11-01 · **itm_qty = 0.00**
     ابراهيم حمدي 2 (26)  · 2026-11-01 · itm_qty = 1.00
   وعندنا: المعمورة qty 2 · سان qty 1 — يعني **سان صح والمعمورة بايتة**.

   السبب: مزامنة الصلاحيات `interval_minutes = 1440` (مرة في اليوم،
   آخر مرة 27/10 الساعة 5:50م)، بينما باقي المزامنات 1 أو 5 أو 60
   دقيقة. الدفعة اتباعت بعد المزامنة، وبما إننا بطّلنا نمسح
   (migrate_165) الصف فضل بآخر كمية اتشافت.

   ⚠️ وقاعدة «له رصيد» (`last_seen` = آخر يوم مزامنة للفرع) **مابتمسكش
      الحالة دي** — الصف اتحدّث في آخر مزامنة فعلًا، والكمية كانت 2
      ساعتها. القاعدة بتمسك الدفعة اللي خلصت من **يوم أو أكتر**، مش
      اللي خلصت من ساعات.

   المقياس: **62 دفعة من 677 (9%) رصيد صنفها في فرعها صفر** — 109 وحدة.

   ── التغيير ─────────────────────────────────────────────────────
   1) `get_expiry_watch` بيقارن بـ`stock_flat` (بيتحدّث كل دقايق، مش
      كل يوم): الصنف اللي رصيده في الفرع صفر دفعته **ماتتعرضش** في
      الوضع الافتراضي، وبيرجع عمود `in_stock` عشان الشاشة تعلّمه لو
      المستخدم شال فلتر «اللي له رصيد».
      ⚠️ الصنف اللي **مش في الكتالوج** رصيده مجهول — **بيتعرض**.
         الاتجاه الآمن: نوري اللي مش متأكدين منه، مانخفيش فلوس.
      ⚠️ المقارنة **صفر مقابل غير صفر بس** — الوحدتين مختلفتين
         (الصلاحيات بالشريط و stock_flat بالعلبة) فأي مقارنة كمية
         بينهم غلط. راجع [[unit-trap-strips-vs-boxes]].

   2) المزامنة من **1440 → 240 دقيقة** (كل ٤ ساعات بدل مرة في اليوم).
      ٦ مرات بدل مرة، وبرضه خفيفة على eplus اللي بيتقل فجأة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

update public.sync_jobs
   set interval_minutes = 240, updated_at = now()
 where name = 'تواريخ الصلاحية' and interval_minutes <> 240;

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
           (r.last_seen = r.live_day)  as is_live,
           /* رصيد الصنف في فرعه — من stock_flat اللي بيتحدّث كل دقايق.
              مش موجود في الكتالوج = مجهول = بنعتبره موجود. */
           case when sf.itm_code is null then true
                else coalesce(case r.branch when 'mamora' then sf.m_q when 'san' then sf.s_q
                                   when 'bishr' then sf.b_q else sf.f_q end, 0) > 0
           end as in_stock
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
     where (not p_live_only or (t.is_live and t.in_stock))
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
               'in_stock',     f.in_stock,
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
