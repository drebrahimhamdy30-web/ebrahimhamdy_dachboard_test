/* ═══════════════════════════════════════════════════════════════════
   مرتجع الفائض للمورّد — get_purchase_surplus_return  (تقرير عرض لحظي)
   ═══════════════════════════════════════════════════════════════════
   تبويب جديد في شاشة فواتير الشراء: الأصناف اللي اشتريناها وعندها فائض
   «محدش محتاجه» → مرشّحة للمرتجع للمورّد اللي اشترينا منه.

   ⚠️ مفيش حساب فائض/معدل جديد — بنقرا نفس المصدر الموحّد:
     • معدل الفائض   = consumption_flat.sur_<فرع>        (معدل شهري)
     • الرصيد        = stock_flat.<حرف>_q
     • كمية الفائض   = floor(الرصيد − معدل الفائض) بشرط الرصيد ≥ الحد الأدنى
                       وإعداد الفرع×التصنيف مفعّل  — نفس معادلة get_purchase_orders
     • الاحتياج      = floor(req_qty(av_<فرع>, الرصيد, min_immediate, reorder_ratio))
   «الفائض اللي محدش محتاجه» للفرع = الفائض − احتياج باقي الفروع (تحويل داخلي الأول).
   محافظ (conservative): لو أكتر من فرع عنده فائض بيطرح احتياج الباقي من كلٍّ،
   فالمقترح للمرتجع بيطلع أصغر — وده الاتجاه الآمن (مانرجّعش حاجة محتاجينها).

   الفلاتر (الفرع/المورّد/الفترة) بتصفّي **المشتريات المعروضة** بس؛ الفائض
   بيتحسب على الرصيد الحالي دايمًا (لحظي، مش متخزّن). المورّد = ilike جزئي.
   بيرجّع صف لكل (فرع × مورّد اشترينا منه) عشان تفلتر بالمورّد وتشوف كل مرتجعاته.

   يتطبّق على: السحابة **و** السيرفر الذاتي. (لا يحتاج refresh — لحظي.)
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_purchase_surplus_return(
  p_branch text default null,
  p_vendor text default null,
  p_from   date default null,
  p_to     date default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_sfx text := '';
  v_sql text;
  v_out jsonb;
  r     record;
begin
  /* صفوف الفائض لكل فرع — طول (branch,itm_code) — للأصناف اللي اتشرت فقط */
  for r in select * from public.branch_letters() loop
    v_sfx := v_sfx
      || case when v_sfx = '' then '' else ' union all ' end
      || ' select ' || quote_literal(r.code) || '::text branch,'
      || '        ' || quote_literal(r.name) || '::text branch_ar,'
      || '        sf.itm_code,'
      || '        coalesce(sf.' || quote_ident(r.letter || '_q') || ',0)::numeric q,'
      || '        coalesce(cf.' || quote_ident('sur_' || r.code) || ',0)::numeric sr,'
      || '        coalesce(cf.' || quote_ident('av_'  || r.code) || ',0)::numeric av,'
      || '        public.item_category(sf.co, sf.med) cat'
      || '   from stock_flat sf'
      || '   left join consumption_flat cf on cf.code = sf.itm_code'
      || '  where exists (select 1 from purchase_invoice_items z where z.itm_code = sf.itm_code)';
  end loop;

  v_sql :=
       'with cfg as (select min_immediate mn, reorder_ratio ratio, min_stock_surplus mss'
    || '               from purchase_settings where id = 1),'
    || ' sfx as (' || v_sfx || '),'
    || ' calc as ('
    || '   select x.*,'
    || '          floor(public.req_qty(x.av, x.q, (select mn from cfg), (select ratio from cfg)))::int req,'
    || '          case when g.branch is null then 0'
    || '               when x.q >= coalesce(g.min_stock_surplus, (select mss from cfg))'
    || '                and floor(x.q - x.sr) > 0'
    || '               then floor(x.q - x.sr)::int else 0 end surplus'
    || '     from sfx x'
    || '     left join branch_calc_settings g'
    || '       on g.branch = x.branch_ar and g.category = x.cat and g.active'
    || ' ),'
    || ' tot as (select itm_code, sum(req) total_req from calc group by itm_code),'
    || ' ret as ('
    || '   select c.*, t.total_req,'
    || '          greatest(0, c.surplus - greatest(0, t.total_req - c.req))::int returnable'
    || '     from calc c join tot t using (itm_code)'
    || '    where c.surplus > 0'
    || ' ),'
    || ' pur as ('
    || '   select pii.branch, pii.itm_code, pih.ven_name_ar vendor,'
    || '          sum(pii.qnty)::numeric bought_qty, count(*)::int n_lines, max(pii.itm_name) pname,'
    /* الفاتورة اللي هنرجّع منها = أحدث فاتورة من المورّد ده للصنف (نفس مصدر سعر الشراء) */
    || '          (array_agg(pih.ven_bill_date order by pih.ven_bill_date desc nulls last, pih.pth_id desc))[1] last_bill,'
    || '          (array_agg(pih.ven_bill_no  order by pih.ven_bill_date desc nulls last, pih.pth_id desc))[1] last_bill_no,'
    || '          (array_agg(pih.pth_id       order by pih.ven_bill_date desc nulls last, pih.pth_id desc))[1] last_pth,'
    || '          (array_agg(pii.itm_pur_price order by pih.ven_bill_date desc nulls last, pih.pth_id desc))[1] last_price'
    || '     from purchase_invoice_items pii'
    || '     join purchase_invoices pih on pih.branch = pii.branch and pih.pth_id = pii.pth_id'
    || '    where pii.itm_code is not null'
    || '      and ($3 is null or pih.ven_bill_date::date >= $3)'
    || '      and ($4 is null or pih.ven_bill_date::date <= $4)'
    || '      and ($1 is null or pii.branch = $1)'
    || '      and ($2 is null or pih.ven_name_ar ilike ''%'' || $2 || ''%'')'
    || '    group by pii.branch, pii.itm_code, pih.ven_name_ar'
    || ' )'
    || ' select coalesce(jsonb_agg(to_jsonb(t)'
    || '          order by t.returnable desc, t.ret_value desc nulls last, t.itm_code), ''[]''::jsonb)'
    || '   from ('
    || '     select r.branch, r.branch_ar, r.itm_code,'
    || '            coalesce(nullif(btrim(cf.itm_name),''''), nullif(btrim(sf.n),''''), p.pname) itm_name,'
    || '            r.q stock,'
    /* المستهدف = اللي الفرع يحتفظ به (معدل الفائض) + احتياج باقي الفروع (الهدف لكل الفروع) */
    || '            round(r.sr + greatest(0, r.total_req - r.req))::numeric target,'
    || '            r.returnable,'
    || '            p.vendor, p.last_bill_no bill_no, p.last_pth, p.last_bill bill_date, p.bought_qty, p.last_price,'
    || '            round(coalesce(p.last_price,0) * least(r.returnable, p.bought_qty))::numeric ret_value'
    || '       from ret r'
    || '       join pur p on p.branch = r.branch and p.itm_code = r.itm_code'
    || '       left join consumption_flat cf on cf.code = r.itm_code'
    || '       left join stock_flat sf on sf.itm_code = r.itm_code'
    || '      where r.returnable > 0'
    || '   ) t';

  execute v_sql into v_out using p_branch, p_vendor, p_from, p_to;
  return coalesce(v_out, '[]'::jsonb);
end
$fn$;

grant execute on function public.get_purchase_surplus_return(text,text,date,date) to anon, authenticated;
notify pgrst, 'reload schema';
