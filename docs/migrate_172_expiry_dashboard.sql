/* ═══════════════════════════════════════════════════════════════════
   داشبورد الصلاحيات — اللي جاي، واللي اتلف، وفين المشكلة
   ═══════════════════════════════════════════════════════════════════
   طلب المالك: تبويب يبني عليه قرارات — يقلّل الأصناف القريبة من
   الانتهاء، ويشوف المنحنى بيزيد ولا بيقل شهريًا.

   ── مصدرين مختلفين، كل واحد بيجاوب سؤال ────────────────────────
   • **اللي جاي** (`item_expiry`): المخزون الحالي موزّع على شهور
     انتهائه. بيقول «فبراير 2027 فيه 187 ألف معرّضة — ابدأ دلوقتي».
     ⚠️ المنحنى ده **بيزيد طبيعيًا** كل ما تبعد في المستقبل، لأن
     المخزون البعيد لسه ماتباعش. المقارنة المفيدة لنفس الشهر مع
     الوقت، مش بين الشهور.
   • **اللي اتلف** (`stock_adjustments`، migrate_171): حركات تصفير
     الأرصدة بسببها. ده الرقم الحقيقي للخسارة، لأن **الأرصدة
     بتتصفّر يدويًا** فالرصيد صفر مش معناه بيع.

   ── الأعمدة بتتحل بالجسر ────────────────────────────────────────
   المصدرين بيجيبوا `itm_id` خام من eplus، فالاسم والشركة بيتحلّوا
   عبر `eplus_id_code`. راجع [[eplus-itmid-code-bridge]].

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_expiry_dashboard(
  p_branch     text default null,
  p_back       int  default 12,   -- شهور للخلف (الإتلاف)
  p_fwd        int  default 12,   -- شهور للأمام (المعرّض)
  p_company    text default null,
  p_top        int  default 10
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_scope text := public.purchase_branch_scope(p_branch, 'expiry');
  v_back  int  := greatest(1, least(coalesce(p_back, 12), 36));
  v_fwd   int  := greatest(1, least(coalesce(p_fwd, 12), 36));
  v_top   int  := greatest(3, least(coalesce(p_top, 10), 50));
  v_out   jsonb;
begin
  with
  live as (select branch, max(last_seen) d from item_expiry group by branch),
  /* ── المعرّض: المخزون الحالي بشهر انتهائه ── */
  fwd as (
    select e.branch, e.exp_date, e.qty, e.cost_total,
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
           case f.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san
                when 'bishr' then cf.av_bishr else cf.av_seyouf end rate
      from fwd f
      left join stock_flat sf       on sf.itm_code = f.code
      left join consumption_flat cf on cf.code     = f.code
     where (p_company is null or sf.co = p_company)
  ),
  /* ── المتلف: حركات التصفير بسببها ── */
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
  )
  select jsonb_build_object(
    'scope', v_scope,
    /* منحنى المعرّض بالشهر */
    'forward', coalesce((select jsonb_agg(x order by x->>'m')
       from (select jsonb_build_object(
               'm', to_char(exp_date,'YYYY-MM'),
               'batches', count(*), 'items', count(distinct code),
               'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0))) x
             from fwd2 group by to_char(exp_date,'YYYY-MM')) q), '[]'::jsonb),
    /* منحنى المتلف بسبب الانتهاء بالشهر */
    'expired', coalesce((select jsonb_agg(x order by x->>'m')
       from (select jsonb_build_object(
               'm', to_char(changed_at,'YYYY-MM'),
               'rows', count(*), 'qty', round(sum(diff),2),
               'cost', round(sum(cost_value))) x
             from adj2 where cause_id = 2 group by to_char(changed_at,'YYYY-MM')) q), '[]'::jsonb),
    /* كل الأسباب في الفترة */
    'causes', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'cause', coalesce(cause,'(بدون سبب)'), 'cause_id', cause_id,
               'rows', count(*), 'qty', round(sum(diff),2),
               'cost', round(sum(cost_value))) x
             from adj2 group by cause_id, cause) q), '[]'::jsonb),
    /* فين المشكلة — أعلى شركات بالمعرّض */
    'top_companies', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'company', coalesce(company,'—'), 'batches', count(*),
               'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0))) x
             from fwd2 group by company
             order by coalesce(sum(cost_total),0) desc limit v_top) q), '[]'::jsonb),
    /* أعلى أصناف بالمعرّض */
    'top_items', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'code', code, 'name', coalesce(itm_name,'—'),
               'company', coalesce(company,'—'),
               'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)),
               'sold', bool_or(coalesce(rate,0) > 0)) x
             from fwd2 group by code, itm_name, company
             order by coalesce(sum(cost_total),0) desc limit v_top) q), '[]'::jsonb),
    /* بالفرع: معرّض مقابل متلف */
    'by_branch', coalesce((select jsonb_agg(x order by (x->>'cost')::numeric desc)
       from (select jsonb_build_object(
               'branch', b,
               'cost', round(coalesce((select sum(cost_total) from fwd2 where fwd2.branch = b),0)),
               'qty',  round(coalesce((select sum(qty)        from fwd2 where fwd2.branch = b),0),2),
               'expired_cost', round(coalesce(
                  (select sum(cost_value) from adj2 where adj2.branch = b and cause_id = 2),0))) x
             from (select distinct branch b from fwd2
                   union select distinct branch from adj2) s) q), '[]'::jsonb),
    /* الأخطر: معرّض ومابيتباعش */
    'unsold', (select jsonb_build_object(
                 'batches', count(*), 'items', count(distinct code),
                 'qty', round(sum(qty),2), 'cost', round(coalesce(sum(cost_total),0)))
               from fwd2 where coalesce(rate,0) = 0),
    'totals', jsonb_build_object(
      'fwd_cost',     (select round(coalesce(sum(cost_total),0)) from fwd2),
      'fwd_batches',  (select count(*) from fwd2),
      'exp_cost',     (select round(coalesce(sum(cost_value),0)) from adj2 where cause_id = 2),
      'exp_rows',     (select count(*) from adj2 where cause_id = 2),
      'adj_cost',     (select round(coalesce(sum(cost_value),0)) from adj2 where diff > 0),
      'months_back',  v_back, 'months_fwd', v_fwd)
  ) into v_out;

  return v_out;
end$fn$;

revoke all on function public.get_expiry_dashboard(text,int,int,text,int) from public, anon;
grant execute on function public.get_expiry_dashboard(text,int,int,text,int) to authenticated;

notify pgrst, 'reload schema';
