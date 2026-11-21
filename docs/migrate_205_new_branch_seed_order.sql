-- ٢٠٥: طلبية تأسيس فرع من فرع مرجع — «موجود عند المرجع وناقص عندنا»
--
-- الليه: السيوف فرع جديد، ومعدله الذاتي صفر في الأصناف اللى ماباعهاش،
-- فشاشة الطلبيات مابتطلبهاش أصلًا. المالك عايز يملا النواقص بالمقارنة
-- بفرع ناضج (سان ستيفانو) **بنفس منطق الشراء** مش بقائمة عشوائية.
--
-- الدالة بتمشي على نفس معادلات المحرك بالحرف:
--   • المعدل المشتق  = هدف المرجع × نسبة الشريحة من new_branch_rate_tiers
--     (نفس تعبير get_consumption_rates: الشريحة تتختار بـrate_min desc)
--   • المطلوب        = req_qty(المعدل, الرصيد, min_immediate, reorder_ratio)
--                      من purchase_settings — نفس دالة المحرك
--   • الفائض         = رصيد الفرع − معدل فائضه، لو الرصيد ≥ min_stock_surplus
--   • صافي الشراء    = المطلوب − **أكبر** فائض عند فرع واحد (مش المجموع،
--                      لأن التحويلة بتيجي من فرع واحد — نفس قاعدة المحرك)
--   • أرخص مخزن      = best_store_for(الفرع, الكود) — بتحترم branch_stores
--
-- بترجّع كمان `qty_alt` = نفس الحساب لو الشريحة الأولى ١٠٪ بدل ١٠٠٪.
-- السبب: الشرائح المخزّنة دلوقتي ≥٢→١٠٠٪ · ≥٥→٢٠٪ · ≥١٠→٢٥٪ — يعني
-- معدل ٤.٩ ياخد تغطية كاملة ومعدل ٥.١ ياخد خُمس، وده مقلوب. البذرة
-- الأصلية كانت ١٠٪. العمود للمقارنة لحد ما المالك يقرر.
--
-- ملاحظة: مش مقصورة على الأدوية — purchase_orders_flat بتفلتر med=1،
-- لكن المقارنة دي بتشمل كل التصنيفات وبترجّع العمود عشان الفلترة تبقى
-- قرار المستخدم.

begin;

create or replace function public.get_new_branch_seed_order(
  p_target text, p_source text)
returns table (
  itm_code text, itm_name text, company text, unit text, cat text,
  src_stock numeric, src_base numeric, src_target numeric, tier_pct numeric,
  derived_rate numeric, req_qty_n int,
  surplus_max int, surplus_branch text,
  net_qty int, net_qty_alt int,
  store text, price numeric, disc numeric, net_price numeric, line_value numeric
)
language plpgsql stable security definer set search_path to 'public'
set statement_timeout to '120s'
as $function$
declare
  v_tl text; v_sl text; v_mn numeric; v_ratio numeric; v_mss numeric; v_sql text;
  v_oth text := ''; v_sur text := '';
  r record;
begin
  /* الحارس بيتطبّق لما يكون فيه توكن مستخدم بس — نفس نمط
     refresh_purchase_orders. من غير الشرط ده أي تشغيل إداري أو مجدول
     (بلا JWT) بيفشل، وده الفخ اللى اتسجّل فى cron-role-guard-trap. */
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    perform require_app_role(array['admin','manager','pharmacist']);
  end if;

  select letter into v_tl from public.branch_letters() where name = p_target;
  select letter into v_sl from public.branch_letters() where name = p_source;
  if v_tl is null then raise exception 'فرع غير معروف: %', p_target; end if;
  if v_sl is null then raise exception 'فرع غير معروف: %', p_source; end if;
  if v_tl = v_sl then raise exception 'الفرع والمرجع واحد'; end if;

  select min_immediate, reorder_ratio, min_stock_surplus
    into v_mn, v_ratio, v_mss from purchase_settings where id = 1;

  /* فائض كل فرع غير الهدف — نفس تعبير get_purchase_orders */
  for r in select * from public.branch_letters() where letter <> v_tl loop
    v_sur := v_sur || case when v_sur = '' then '' else ', ' end
          || '(case when coalesce(sf.' || quote_ident(r.letter||'_q') || ',0) >= ' || v_mss
          || '       and floor(coalesce(sf.' || quote_ident(r.letter||'_q') || ',0)'
          || '                 - coalesce(cf.' || quote_ident('sur_'||r.code) || ',0)) > 0'
          || '      then floor(coalesce(sf.' || quote_ident(r.letter||'_q') || ',0)'
          || '                 - coalesce(cf.' || quote_ident('sur_'||r.code) || ',0))'
          || '      else 0 end)::int';
    v_oth := v_oth || case when v_oth = '' then '' else ', ' end
          || quote_literal(r.name);
  end loop;

  v_sql :=
    'with b as ('
 || '  select sf.itm_code, coalesce(nullif(sf.n,''''), cf.itm_name) itm_name,'
 || '         sf.co company, sf.u unit, public.item_category(sf.co, sf.med) cat,'
 || '         coalesce(sf.' || quote_ident(v_sl||'_q') || ',0)::numeric src_stock,'
 || '         coalesce(cf.' || quote_ident('base_'||(select code from public.branch_letters() where letter=v_sl)) || ',0)::numeric src_base,'
 || '         coalesce(cf.' || quote_ident('av_'||(select code from public.branch_letters() where letter=v_sl)) || ',0)::numeric src_target,'
 || '         coalesce(sf.' || quote_ident(v_tl||'_q') || ',0)::numeric tgt_stock,'
 || '         array[' || v_sur || '] surs, array[' || v_oth || ']::text[] brs'
 || '    from stock_flat sf left join consumption_flat cf on cf.code = sf.itm_code'
 || '   where sf.itm_code not in (select itm_code from archived_items)'
 || '     and coalesce(sf.' || quote_ident(v_sl||'_q') || ',0) > 0'
 || '     and coalesce(sf.' || quote_ident(v_tl||'_q') || ',0) <= 0'
 || '), t as ('
 || '  select b.*,'
 || '         coalesce((select x.percent from new_branch_rate_tiers x'
 || '                    where b.src_target >= x.rate_min order by x.rate_min desc limit 1), 0) pct'
 || '    from b'
 || '), q as ('
 || '  select t.*,'
 || '         round(t.src_target * t.pct / 100.0, 1) rate_now,'
 || '         round(t.src_target * (case when t.pct = 100 then 10 else t.pct end) / 100.0, 1) rate_alt'
 || '    from t where t.pct > 0'
 || '), n as ('
 || '  select q.*,'
 || '         floor(req_qty(q.rate_now, q.tgt_stock, $1, $2))::int req_n,'
 || '         floor(req_qty(q.rate_alt, q.tgt_stock, $1, $2))::int req_a,'
 || '         (select max(s) from unnest(q.surs) s)::int smax,'
 || '         (select q.brs[i] from generate_subscripts(q.surs,1) i'
 || '           order by q.surs[i] desc limit 1) sbr'
 || '    from q'
 || ')'
 || ' select n.itm_code, n.itm_name, n.company, n.unit, n.cat,'
 || '        n.src_stock, n.src_base, n.src_target, n.pct, n.rate_now, n.req_n,'
 || '        n.smax, (case when n.smax > 0 then n.sbr else null end),'
 || '        greatest(0, n.req_n - n.smax)::int,'
 || '        greatest(0, n.req_a - n.smax)::int,'
 || '        bs.store, bs.price, bs.discount_perc,'
 || '        round(bs.price * (1 - coalesce(bs.discount_perc,0)/100.0), 2),'
 || '        round(bs.price * (1 - coalesce(bs.discount_perc,0)/100.0)'
 || '              * greatest(0, n.req_n - n.smax), 2)'
 || '   from n left join lateral best_store_for($3, n.itm_code) bs on true'
 || '  where n.req_n > 0'
 || '  order by greatest(0, n.req_n - n.smax) desc, n.src_target desc, n.itm_code';

  return query execute v_sql using v_mn, v_ratio, p_target;
end$function$;

revoke all on function public.get_new_branch_seed_order(text, text) from public, anon;
grant execute on function public.get_new_branch_seed_order(text, text) to authenticated, service_role;

commit;
