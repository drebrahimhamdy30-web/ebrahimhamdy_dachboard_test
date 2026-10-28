/* ═══════════════════════════════════════════════════════════════════
   لوحة متابعة Nearly Expire — النسخة التانية
   ═══════════════════════════════════════════════════════════════════
   اللي اتغيّر عن `migrate_172` بعد مراجعة التصوّر مع المالك:

   1. **بارامتر الشهر** `p_month` (YYYY-MM): الضغط على عمود في الرسم
      بيجيب تفاصيل الشهر ده **من السيرفر**، مش بفلترة في المتصفح على
      بيانات ناقصة. لو الشهر في الماضي بيرجّع أصناف التلف، ولو في
      المستقبل بيرجّع أصناف المعرّض.

   2. **الأسباب اتفصلت خروج/دخول** بدل الصافي. السبب: على 12 شهر بند
      «بدون سبب» صافيه **سالب ١.٨٩ مليون** (دخول أكتر من خروج)، فالصافي
      كان بيوحي إنه مش مشكلة بينما هو ٧ مليون خارج و٨.٩ داخل — تسويات
      جرد رايحة جاية. الصافي بيخبّي الحجم.

   3. **`expired` بقى خروج صافي موجب بس** (`diff > 0`). المرتجعات
      (٤ صفوف، ١,٦٤٥ج) ماتخصمش من رقم التلف.

   4. **`forward` فيه `unsold`** لكل شهر — تكلفة المعرّض اللي الصنف
      بتاعه ملوش أي معدل بيع في فرعه. ده الرقم اللي بيتبنى عليه قرار
      «أرجّع دلوقتي» بدل الانتظار.

   ⚠️ حلّ الكود: **لو الكود الخام موجود في `stock_flat` بنسيبه زي ما هو**
      وماننادش الجسر — الجسر لآخر حل. أي عكس ده بيغيّر نسبة الشركات
      بحوالي ١٪ من غير سبب.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

drop function if exists public.get_expiry_dashboard(text,int,int,text,int);

create or replace function public.get_expiry_dashboard(
  p_branch     text default null,
  p_back       int  default 12,   -- شهور للخلف (الإتلاف)
  p_fwd        int  default 12,   -- شهور للأمام (المعرّض)
  p_company    text default null,
  p_top        int  default 10,
  p_month      text default null  -- 'YYYY-MM' لتفاصيل شهر واحد
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_scope text := public.purchase_branch_scope(p_branch, 'expiry');
  v_back  int  := greatest(1, least(coalesce(p_back, 12), 36));
  v_fwd   int  := greatest(1, least(coalesce(p_fwd, 12), 36));
  v_top   int  := greatest(3, least(coalesce(p_top, 10), 50));
  v_m     text := nullif(btrim(coalesce(p_month, '')), '');
  v_mkind text := null;
  v_out   jsonb;
begin
  if v_m is not null and v_m !~ '^\d{4}-\d{2}$' then v_m := null; end if;
  if v_m is not null then
    v_mkind := case when (v_m || '-01')::date < date_trunc('month', current_date)::date
                    then 'exp' else 'fwd' end;
  end if;

  with
  live as (select branch, max(last_seen) d from item_expiry group by branch),
  fwd as (
    select e.branch, e.exp_date, e.qty, e.cost_total,
           /* الكود الخام أولًا، والجسر آخر حل */
           case when s0.itm_code is not null then e.itm_code
                else coalesce(m.itm_code, e.itm_code) end as code
      from item_expiry e
      join live lv on lv.branch = e.branch and e.last_seen = lv.d
      left join stock_flat s0   on s0.itm_code = e.itm_code
      left join eplus_id_code m on m.itm_id::text = e.itm_code
     where e.exp_date >= current_date
       and e.exp_date <  current_date + (v_fwd || ' months')::interval
       and (v_scope is null or e.branch = v_scope)
  ),
  fwd2 as (
    select f.*, sf.n itm_name, sf.co company,
           coalesce(case f.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san
                when 'bishr' then cf.av_bishr else cf.av_seyouf end, 0) rate
      from fwd f
      left join stock_flat sf       on sf.itm_code = f.code
      left join consumption_flat cf on cf.code     = f.code
     where (p_company is null or sf.co = p_company)
  ),
  adj as (
    select a.*,
           case when s0.itm_code is not null then a.itm_code
                else coalesce(m.itm_code, a.itm_code) end as code
      from stock_adjustments a
      left join stock_flat s0   on s0.itm_code = a.itm_code
      left join eplus_id_code m on m.itm_id::text = a.itm_code
     where a.changed_at >= (date_trunc('month', current_date) - (v_back || ' months')::interval)
       and (v_scope is null or a.branch = v_scope)
  ),
  adj2 as (
    select a.*, sf.n itm_name, sf.co company
      from adj a left join stock_flat sf on sf.itm_code = a.code
     where (p_company is null or sf.co = p_company)
  ),
  /* التلف = خروج فعلي بسبب «منتهى صلاحية» */
  exp2 as (select * from adj2 where cause_id = 2 and diff > 0)
  select jsonb_build_object(
    'scope', v_scope,

    'forward', coalesce((select jsonb_agg(x order by x->>'m')
       from (select jsonb_build_object(
               'm', to_char(exp_date,'YYYY-MM'),
               'batches', count(*), 'items', count(distinct code),
               'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)),
               'unsold', round(coalesce(sum(cost_total) filter (where rate = 0), 0))) x
             from fwd2 group by to_char(exp_date,'YYYY-MM')) q), '[]'::jsonb),

    'expired', coalesce((select jsonb_agg(x order by x->>'m')
       from (select jsonb_build_object(
               'm', to_char(changed_at,'YYYY-MM'),
               'rows', count(*), 'qty', round(sum(diff),2),
               'cost', round(sum(cost_value))) x
             from exp2 group by to_char(changed_at,'YYYY-MM')) q), '[]'::jsonb),

    /* خروج ودخول منفصلين — الصافي بيخبّي حجم تسويات الجرد */
    'causes', coalesce((select jsonb_agg(x order by (x->>'out_cost')::numeric desc nulls last)
       from (select jsonb_build_object(
               'cause', coalesce(cause,'(بدون سبب)'), 'cause_id', cause_id,
               'out_rows', count(*) filter (where diff > 0),
               'out_cost', round(coalesce(sum(cost_value) filter (where diff > 0), 0)),
               'in_rows',  count(*) filter (where diff < 0),
               'in_cost',  round(coalesce(-sum(cost_value) filter (where diff < 0), 0))) x
             from adj2 group by cause_id, cause) q), '[]'::jsonb),

    'top_companies', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'company', coalesce(company,'—'), 'batches', count(*),
               'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)),
               'unsold', round(coalesce(sum(cost_total) filter (where rate = 0), 0))) x
             from fwd2 group by company
             order by coalesce(sum(cost_total),0) desc limit v_top) q), '[]'::jsonb),

    'by_branch', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'branch', b,
               'cost',    round(coalesce((select sum(cost_total) from fwd2 where fwd2.branch = b),0)),
               'batches',       coalesce((select count(*)        from fwd2 where fwd2.branch = b),0),
               'unsold',  round(coalesce((select sum(cost_total) from fwd2
                                           where fwd2.branch = b and fwd2.rate = 0),0)),
               'expired_cost', round(coalesce(
                  (select sum(cost_value) from exp2 where exp2.branch = b),0)),
               'expired_rows', coalesce(
                  (select count(*) from exp2 where exp2.branch = b),0)) x
             from (select distinct branch b from fwd2
                   union select distinct branch from exp2) s) q), '[]'::jsonb),

    /* تفاصيل شهر واحد — من السيرفر مش من المتصفح */
    'month', case when v_m is null then null else jsonb_build_object(
      'm', v_m, 'kind', v_mkind,
      'items', coalesce(case when v_mkind = 'fwd' then
        (select jsonb_agg(x order by (x->>'cost')::numeric desc)
           from (select jsonb_build_object(
                   'code', code, 'name', coalesce(itm_name,'—'),
                   'company', coalesce(company,'—'), 'branch', branch,
                   'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)),
                   'sold', bool_or(rate > 0)) x
                 from fwd2 where to_char(exp_date,'YYYY-MM') = v_m
                 group by code, itm_name, company, branch
                 order by coalesce(sum(cost_total),0) desc limit v_top) q)
        else
        (select jsonb_agg(x order by (x->>'cost')::numeric desc)
           from (select jsonb_build_object(
                   'code', code, 'name', coalesce(itm_name,'—'),
                   'company', coalesce(company,'—'), 'branch', branch,
                   'qty', round(sum(diff),2), 'cost', round(sum(cost_value)),
                   'sold', null) x
                 from exp2 where to_char(changed_at,'YYYY-MM') = v_m
                 group by code, itm_name, company, branch
                 order by sum(cost_value) desc limit v_top) q)
        end, '[]'::jsonb)) end,

    /* أعلى الأصناف لما مفيش شهر مختار */
    'top_items', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'code', code, 'name', coalesce(itm_name,'—'),
               'company', coalesce(company,'—'), 'branch', branch,
               'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)),
               'sold', bool_or(rate > 0)) x
             from fwd2 group by code, itm_name, company, branch
             order by coalesce(sum(cost_total),0) desc limit v_top) q), '[]'::jsonb),

    /* أكبر دفعة واقفة بلا بيع — بطاقة التحذير */
    'worst_unsold', (select jsonb_build_object(
            'code', code, 'name', coalesce(itm_name,'—'), 'company', coalesce(company,'—'),
            'branch', branch, 'm', to_char(exp_date,'YYYY-MM'),
            'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)))
          from fwd2 where rate = 0
          group by code, itm_name, company, branch, to_char(exp_date,'YYYY-MM')
          order by coalesce(sum(cost_total),0) desc limit 1),

    'unsold', (select jsonb_build_object(
                 'batches', count(*), 'items', count(distinct code),
                 'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)))
               from fwd2 where rate = 0),

    'totals', jsonb_build_object(
      'fwd_cost',     (select round(coalesce(sum(cost_total),0)) from fwd2),
      'fwd_batches',  (select count(*) from fwd2),
      'fwd_items',    (select count(distinct code) from fwd2),
      'exp_cost',     (select round(coalesce(sum(cost_value),0)) from exp2),
      'exp_rows',     (select count(*) from exp2),
      'months_back',  v_back, 'months_fwd', v_fwd)
  ) into v_out;

  return v_out;
end$fn$;

revoke all on function public.get_expiry_dashboard(text,int,int,text,int,text) from public, anon;
grant execute on function public.get_expiry_dashboard(text,int,int,text,int,text) to authenticated;

notify pgrst, 'reload schema';
