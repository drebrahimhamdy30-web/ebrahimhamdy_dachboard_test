/* ═══════════════════════════════════════════════════════════════════
   مرتجع الفائض للمورّد — get_purchase_surplus_return  (تقرير عرض لحظي)
   ═══════════════════════════════════════════════════════════════════
   تبويب في شاشة فواتير الشراء: الأصناف اللي اشتريناها وعندها فائض عن
   الهدف الكلي → مرشّحة للمرتجع للمورّد اللي اشترينا منه.

   ⚠️ الفائض **كلي لكل الفروع** (زي «إجمالي الهدف/الرصيد» في شاشة الطلبيات):
     • إجمالي الرصيد  = Σ stock_flat.<حرف>_q           (كل الفروع)
     • إجمالي الهدف   = Σ consumption_flat.av_<فرع>     (كل الفروع) = المستهدف
     • الفائض         = floor(إجمالي الرصيد − إجمالي الهدف)  (> 0 فقط)
   كده التحويل الداخلي متحسوب ضمنيًا: لو فرع تحت هدفه، إجمالي الهدف بيرتفع
   فالفائض بيقل أو يختفي — فمانرجّعش حاجة محتاجينها في أي فرع.

   الفلاتر (الفرع/المورّد/الفترة) بتصفّي **المشتريات المعروضة** بس؛ الفائض
   بيتحسب على الرصيد الحالي دايمًا (لحظي، مش متخزّن). المورّد = ilike جزئي.
   بيرجّع صف لكل (فرع شراء × مورّد اشترينا منه)؛ الرصيد/الهدف/الفائض كلية
   (نفسها في كل صفوف الصنف). القابل للمرتجع للمورّد = الأقل من (الفائض/كمية الشراء).

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
  v_stock  text := '';   -- Σ رصيد كل الفروع
  v_target text := '';   -- Σ هدف (av) كل الفروع
  v_sql    text;
  v_out    jsonb;
  r        record;
begin
  for r in select * from public.branch_letters() loop
    v_stock  := v_stock  || ' + coalesce(sf.' || quote_ident(r.letter || '_q') || ',0)';
    v_target := v_target || ' + coalesce(cf.' || quote_ident('av_' || r.code) || ',0)';
  end loop;
  v_stock  := ltrim(v_stock,  ' +');
  v_target := ltrim(v_target, ' +');

  v_sql :=
       'with tot as ('
    || '   select sf.itm_code,'
    || '          (' || v_stock  || ')::numeric total_stock,'
    || '          (' || v_target || ')::numeric total_target,'
    || '          floor((' || v_stock || ') - (' || v_target || '))::int surplus'
    || '     from stock_flat sf'
    || '     left join consumption_flat cf on cf.code = sf.itm_code'
    || '    where exists (select 1 from purchase_invoice_items z where z.itm_code = sf.itm_code)'
    || ' ),'
    || ' pur as ('
    || '   select pii.branch, pii.itm_code, pih.ven_name_ar vendor,'
    || '          sum(pii.qnty)::numeric bought_qty, count(*)::int n_lines, max(pii.itm_name) pname,'
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
    || '     select p.branch,'
    || '            (select bl.name from public.branch_letters() bl where bl.code = p.branch) branch_ar,'
    || '            p.itm_code,'
    || '            coalesce(nullif(btrim(cf.itm_name),''''), nullif(btrim(sf.n),''''), p.pname) itm_name,'
    || '            tt.total_stock stock, tt.total_target target, tt.surplus returnable,'
    || '            p.vendor, p.last_bill_no bill_no, p.last_pth, p.last_bill bill_date, p.bought_qty, p.last_price,'
    || '            least(tt.surplus, p.bought_qty)::int ret_qty,'
    || '            round(coalesce(p.last_price,0) * least(tt.surplus, p.bought_qty))::numeric ret_value'
    || '       from pur p'
    || '       join tot tt on tt.itm_code = p.itm_code and tt.surplus > 0'
    || '       left join consumption_flat cf on cf.code = p.itm_code'
    || '       left join stock_flat sf on sf.itm_code = p.itm_code'
    || '   ) t';

  execute v_sql into v_out using p_branch, p_vendor, p_from, p_to;
  return coalesce(v_out, '[]'::jsonb);
end
$fn$;

grant execute on function public.get_purchase_surplus_return(text,text,date,date) to anon, authenticated;
notify pgrst, 'reload schema';
