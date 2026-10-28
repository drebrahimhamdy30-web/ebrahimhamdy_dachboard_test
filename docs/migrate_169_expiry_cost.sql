/* ═══════════════════════════════════════════════════════════════════
   تكلفة الدفعات القريبة من الانتهاء — من مصدرها في eplus
   ═══════════════════════════════════════════════════════════════════
   ── الخلفية ──────────────────────────────────────────────────────
   المالك سأل: تقرير «أصناف منتهية الصلاحية» في eplus بيجمّع البيانات
   ولا فيه جدول فيه كل ده؟ الفحص على eplus (2026-10-28):

   `Item_Class_Store` فيه **كل عمود في التقرير** مخزّن على مستوى
   الدفعة، مفيش أي حساب:

     c_id · itm_id · sto_id · **ven_id** · itm_qty
     **pharm_price** (التكلفة) · sell_price · sell_tax
     itm_expiry_date · **sec_insert_date** (ت.الشراء)

   اتأكد بمطابقة التقرير المطبوع:
     69690 → تكلفة 130.51 · شراء 2024-05-06 22:14:15  ✓
     65514 → تكلفة 160.00 · شراء 2023-11-12 22:29:12  ✓
     71613 → تكلفة 224.00 · شراء 2026-10-21 16:45:00  ✓

   ومزامنتنا كانت بتاخد **3 أعمدة بس** (الكود والتاريخ والكمية).

   ── ليه ده أهم من إني أحسب التكلفة بنفسي ───────────────────────
   كنت ناوي أجيب آخر سعر شراء من فواتير الشراء وأقسمه على معامل
   التعبئة — وده كان هيبقى **تقدير** وفيه فخ الوحدات (سعر الفاتورة
   بالعلبة والكمية بالوحدة الصغرى، فالتكلفة تطلع أكبر 2–6 أضعاف).
   `pharm_price` **بنفس وحدة `itm_qty`**، فالضرب مباشر وبلا تحويل.
   راجع [[unit-trap-strips-vs-boxes]].

   ── التغيير ─────────────────────────────────────────────────────
   • `item_expiry` + `cost_total` و`last_buy`.
   • المزامنة بتجيب `SUM(itm_qty * pharm_price)` مش سعر الوحدة —
     لأن الصنف الواحد بنفس الصلاحية ممكن يكون **كذا دفعة بتكاليف
     مختلفة**، والمجموع هو الرقم الصحيح. سعر الوحدة يتحسب قسمة.
   • `get_expiry_watch` بيرجّع `cost` للصف و`cost` في الإجماليات،
     محسوبة على **كل المفلتر** مش الصفحة المعروضة.

   ⚠️ الصفوف القديمة `cost_total` فيها null لحد أول مزامنة بعد الترحيل
      — الشاشة بتعرض «—» مش صفر، عشان مانقولش إن تكلفتها صفر.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

alter table public.item_expiry
  add column if not exists cost_total numeric,
  add column if not exists last_buy   timestamp;

comment on column public.item_expiry.cost_total is
  'إجمالي تكلفة الدفعة = SUM(itm_qty * pharm_price) من eplus. بنفس وحدة qty.';
comment on column public.item_expiry.last_buy is
  'آخر تاريخ شراء للدفعة (Item_Class_Store.sec_insert_date).';

/* ── المزامنة تجيب التكلفة ──────────────────────────────────────── */
update public.sync_jobs
   set steps = jsonb_build_array(jsonb_build_object(
         'select',
         'SELECT ''{branch}'' AS branch, t.itm_code, t.exp_date, t.qty, t.cost_total, t.last_buy'
         || ' FROM (SELECT itm_id AS itm_code,'
         || ' CONVERT(varchar(10), itm_expiry_date, 23) AS exp_date,'
         || ' SUM(itm_qty) AS qty,'
         || ' SUM(itm_qty * pharm_price) AS cost_total,'
         || ' MAX(sec_insert_date) AS last_buy'
         || ' FROM Item_Class_Store'
         || ' WHERE itm_qty > 0 AND itm_expiry_date IS NOT NULL'
         || ' AND itm_expiry_date >= GETDATE()'
         || ' AND itm_expiry_date < DATEADD(month, 36, GETDATE())'
         || ' AND sto_id = CASE ''{branch}'' WHEN ''mamora'' THEN 1 WHEN ''san'' THEN 26'
         || ' WHEN ''bishr'' THEN 28 WHEN ''seyouf'' THEN 29 END'
         || ' GROUP BY itm_id, itm_expiry_date) t',
         'target',   'item_expiry',
         'conflict', 'branch,itm_code,exp_date')),
       updated_at = now()
 where id = 'item_expiry';

/* ── القائمة تعرض التكلفة ───────────────────────────────────────── */
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
           e.cost_total, e.last_buy,
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
               'unknown', count(*) filter (where itm_name is null),
               /* التكلفة على كل المفلتر — مش الصفحة المعروضة */
               'cost',    coalesce(sum(cost_total), 0),
               'no_cost', count(*) filter (where cost_total is null))
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
               'cost',         f.cost_total,
               'last_buy',     to_char(f.last_buy, 'YYYY-MM-DD'),
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
