-- migrate_100: get_purchase_surplus_return — إجماليات + ترقيم من السيرفر
-- السبب: الدالة كانت بترجّع كل الصفوف (≈10 آلاف) للمتصفح؛ النسخة القديمة setof
--        كانت بتتقص عند 1000 (أرقام ناقصة)، والنسخة jsonb كاملة كانت بتبعت 3.9 ميجا.
-- الحل: ترجّع { total_count, total_value, rows[صفحة] } — الحساب كله على السيرفر.
-- يتطبّق على: السيرفر الذاتي (السحابة اتعملت عبر MCP بنفس التعريف).

drop function if exists public.get_purchase_surplus_return(text,text,date,date);

create or replace function public.get_purchase_surplus_return(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null,
  p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_stock text := ''; v_target text := ''; v_sql text; v_out jsonb; r record;
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
    || ' ),'
    || ' t as ('
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
    || ' )'
    || ' select jsonb_build_object('
    || '   ''total_count'', (select count(*) from t),'
    || '   ''total_value'', (select coalesce(sum(ret_value),0) from t),'
    || '   ''rows'', coalesce(('
    || '       select jsonb_agg(to_jsonb(x) order by x.returnable desc, x.ret_value desc nulls last, x.itm_code)'
    || '       from (select * from t order by returnable desc, ret_value desc nulls last, itm_code limit $5 offset $6) x'
    || '   ), ''[]''::jsonb))';

  execute v_sql into v_out using p_branch, p_vendor, p_from, p_to, p_limit, p_offset;
  return coalesce(v_out, jsonb_build_object('total_count',0,'total_value',0,'rows','[]'::jsonb));
end
$function$;

grant execute on function public.get_purchase_surplus_return(text,text,date,date,int,int) to anon, authenticated, service_role;
