/* ═══════════════════════════════════════════════════════════════════
   عرض الكمية بالعلبة بدل الوحدة الصغرى
   ═══════════════════════════════════════════════════════════════════
   بعد `migrate_179` بقت التكلفة صح، لكن الكمية فضلت بالوحدة الصغرى
   والتكلفة بالعلبة — فالسطر بيقول «١٥٠» وجنبه «٦٨٢ ج» والقارئ
   يفتكر إن القرص بأربع جنيه ونص.

   الحل: الدالة ترجّع `qty_box = qty / per_box` كمان، والشاشة تعرض
   **علبة واحدة** وتحتها الوحدة الصغرى كسطر صغير. الاتنين بنفس
   الأساس، واللبس بيختفي.

   ⚠️ `qty` المخزّن **ما اتغيّرش** — لسه بالوحدة الصغرى، عشان
      `item_expiry_log` (السجل التاريخي) يفضل معناه ثابت. التحويل
      في العرض بس.
   ⚠️ `per_box` ممكن يكون صفر نظريًا، فـ`nullif` إلزامي وإلا قسمة
      على صفر توقّع الدالة كلها.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_expiry_watch(
  p_branch      text    default null,
  p_months      int     default 4,
  p_company     text    default null,
  p_sold        text    default null,
  p_policy_only boolean default false,
  p_q           text    default null,
  p_live_only   boolean default true,
  p_action      text    default null,
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
  live as (
    select branch, max(last_seen) d from item_expiry group by branch
  ),
  resolved as (
    select e.branch, e.itm_code raw_code, e.exp_date, e.qty, e.last_seen, e.first_seen,
           e.cost_total, e.last_buy, coalesce(e.per_box, 1) as per_box,
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
               /* الإجمالي بالعلبة — نفس أساس التكلفة */
               'qty_box', round(coalesce(sum(qty / nullif(per_box, 0)), 0), 2),
               'unsold',  count(*) filter (where not sold),
               'unknown', count(*) filter (where itm_name is null),
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
               'per_box',      f.per_box,
               'qty_box',      round(f.qty / nullif(f.per_box, 0), 2),
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

revoke all on function public.get_expiry_watch(text,int,text,text,boolean,text,boolean,text,int,int)
  from public, anon;
grant execute on function public.get_expiry_watch(text,int,text,text,boolean,text,boolean,text,int,int)
  to authenticated;

notify pgrst, 'reload schema';
