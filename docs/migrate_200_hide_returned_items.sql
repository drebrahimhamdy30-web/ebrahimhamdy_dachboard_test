-- ٢٠٠: إخفاء الأصناف اللي اتعمل لها مرتجع فعلًا من تبويبي «مرتجع للفائض» و«قرب انتهاء الصلاحية»
--
-- الليه: الشاشة بتقترح أصناف للمرتجع، وفيها أصناف اترجّعت خلاص فبتضيّع وقت المشتريات.
-- الأهم إن المطابقة لازم تكون دقيقة، مش بالصنف وبس — لأن نفس الصنف بيتشترى دفعات
-- كتير بتواريخ صلاحية مختلفة، فمرتجع لدفعة قديمة مايخفيش دفعة تانية لسه في المخزن.
-- القياس على البيانات الحقيقية: في نافذة الصلاحية ١٠٣ سطر عندهم مرتجع لنفس الصنف
-- بس من دفعة تانية — دول كانوا هيتخفوا غلط لو طابقنا بالصنف وحده.
--
-- قواعد المطابقة المعتمدة:
--   • تبويب الصلاحية: المرتجع يُحسب لو كان مسجّل على **نفس سطر الفاتورة**
--     (purchase_invoice_items.itm_back_qty) أو مستند مرتجع عام لنفس الصنف
--     و**نفس تاريخ الصلاحية** (نفس الدفعة). المرتجع العام مابيحملش رقم فاتورة
--     في eplus (اتأكد: صفر من ٨٠٠ صف)، فتاريخ الدفعة هو الرابط الدقيق المتاح.
--   • تبويب الفائض: الصف مجمّع على (فرع + صنف + مورد)، فالمرتجع يُحسب من
--     itm_back_qty بتاع **نفس الفواتير الداخلة في الصف** — ربط مباشر بلا صدفة.
--
-- الإخفاء يحصل في السيرفر مش في المتصفح، لأن تبويب الصلاحية بيقصّ عند ٥٠٠ صف
-- والفائض مقسّم صفحات؛ لو فلترنا في المتصفح كانت الصفوف المرتجعة هتاكل الحصّة.
-- الصفوف المرتجعة جزئيًا تفضل ظاهرة (لسه فيها كمية تترجّع) مع بيان المرتجع.

begin;

/* ───────── تبويب قرب انتهاء الصلاحية ───────── */
drop function if exists public.get_purchase_expiry_review(text, text, date, date, integer);
drop function if exists public.get_purchase_expiry_review_impl(text, text, date, date, integer);

create function public.get_purchase_expiry_review_impl(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null,
  p_months integer default 6, p_show_returned boolean default false)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v jsonb;
begin
  with stk as (
    select 'mamora'::text br, itm_code, sto_qty_big qty from stock_mamora
    union all select 'bishr', itm_code, sto_qty_big from stock_bishr
    union all select 'san',   itm_code, sto_qty_big from stock_san
    union all select 'seyouf',itm_code, sto_qty_big from stock_seyouf
  ), base as (
    select pi.branch, pi.pth_id, h.ven_name_ar,
           coalesce(h.sec_insert_date, h.ven_bill_date) ven_bill_date, h.entered_by,
           pi.itm_code, pi.itm_name, pi.qnty, pi.itm_pur_price, pi.exp_date,
           round((pi.exp_date - current_date)::numeric / 30.44, 1) as months_left,
           s.qty as stock,
           case pi.branch when 'mamora' then cf.av_mamora when 'san' then cf.av_san
                          when 'bishr' then cf.av_bishr when 'seyouf' then cf.av_seyouf end as rate,
           coalesce(pi.itm_back_qty, 0)::numeric line_back,
           coalesce((select sum(r.qty) from purchase_returns r
                      where r.branch = pi.branch
                        and r.itm_code = pi.itm_code
                        and r.ibd_exp_date = pi.exp_date), 0)::numeric batch_back
      from purchase_invoice_items pi
      join purchase_invoices h on h.branch = pi.branch and h.pth_id = pi.pth_id
      left join stk s on s.br = pi.branch and s.itm_code = pi.itm_code
      left join consumption_flat cf on cf.code = pi.itm_code
     where pi.exp_date is not null
       and pi.exp_date < (current_date + make_interval(months => p_months))
       and (p_branch is null or p_branch = '' or pi.branch = p_branch)
       and (p_vendor is null or p_vendor = '' or h.ven_name_ar ilike '%'||p_vendor||'%')
       and (p_from is null or coalesce(h.sec_insert_date, h.ven_bill_date) >= p_from)
       and (p_to is null or coalesce(h.sec_insert_date, h.ven_bill_date) < p_to + 1)
  ), tagged as (
    /* greatest مش جمع: مستند المرتجع العام بيعلّم كمية المرتجع على سطر الفاتورة
       نفسه كمان، فالجمع كان هيعدّه مرتين */
    select b.*, greatest(b.line_back, b.batch_back) ret_qty,
           case when b.line_back >= b.batch_back and b.line_back > 0 then 'line'
                when b.batch_back > 0 then 'batch' else null end ret_src
      from base b
  )
  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) into v from (
    select branch, pth_id, ven_name_ar, ven_bill_date, entered_by, itm_code, itm_name,
           qnty, itm_pur_price, exp_date, months_left, stock, rate, ret_qty, ret_src
      from tagged t
     where coalesce(p_show_returned, false)
        or t.ret_qty <= 0
        or (t.qnty > 0 and t.ret_qty < t.qnty)   -- جزئي يفضل ظاهر
     order by exp_date asc
     limit 500
  ) r;
  return v;
end$function$;

create function public.get_purchase_expiry_review(
  p_branch text, p_vendor text, p_from date, p_to date,
  p_months integer, p_show_returned boolean default false)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select public.get_purchase_expiry_review_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'),
           p_vendor, p_from, p_to, p_months, p_show_returned);
$function$;

/* ───────── تبويب مرتجع للفائض ───────── */
drop function if exists public.get_purchase_surplus_return(text, text, date, date, integer, integer, text);
drop function if exists public.get_purchase_surplus_return_impl(text, text, date, date, integer, integer, text);

create function public.get_purchase_surplus_return_impl(
  p_branch text default null, p_vendor text default null,
  p_from date default null, p_to date default null,
  p_limit integer default 50, p_offset integer default 0,
  p_category text default null, p_show_returned boolean default false)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
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
    || '      and ($7 is null or $7 = ''all'' or public.item_category(sf.co, sf.med) = $7)'
    || ' ),'
    || ' pur as ('
    || '   select pii.branch, pii.itm_code, pih.ven_name_ar vendor,'
    || '          sum(pii.qnty)::numeric bought_qty, count(*)::int n_lines, max(pii.itm_name) pname,'
    || '          sum(coalesce(pii.itm_back_qty,0))::numeric back_qty,'
    || '          (array_agg(pih.ven_bill_date order by coalesce(pih.sec_insert_date, pih.ven_bill_date) desc nulls last, pii.itm_pur_price desc, pih.pth_id desc))[1] last_bill,'
    || '          (array_agg(pih.ven_bill_no  order by coalesce(pih.sec_insert_date, pih.ven_bill_date) desc nulls last, pii.itm_pur_price desc, pih.pth_id desc))[1] last_bill_no,'
    || '          (array_agg(pih.pth_id       order by coalesce(pih.sec_insert_date, pih.ven_bill_date) desc nulls last, pii.itm_pur_price desc, pih.pth_id desc))[1] last_pth,'
    || '          (array_agg(pii.itm_pur_price order by coalesce(pih.sec_insert_date, pih.ven_bill_date) desc nulls last, pii.itm_pur_price desc, pih.pth_id desc))[1] last_price'
    || '     from purchase_invoice_items pii'
    || '     join purchase_invoices pih on pih.branch = pii.branch and pih.pth_id = pii.pth_id'
    || '    where pii.itm_code is not null'
    || '      and ($3 is null or coalesce(pih.sec_insert_date, pih.ven_bill_date)::date >= $3)'
    || '      and ($4 is null or coalesce(pih.sec_insert_date, pih.ven_bill_date)::date <= $4)'
    || '      and ($1 is null or pii.branch = $1)'
    || '      and ($2 is null or pih.ven_name_ar ilike ''%'' || $2 || ''%'')'
    || '    group by pii.branch, pii.itm_code, pih.ven_name_ar'
    || ' ),'
    || ' t as ('
    || '     select p.branch,'
    || '            (select bl.name from public.branch_letters() bl where bl.code = p.branch) branch_ar,'
    || '            p.itm_code,'
    || '            coalesce(nullif(btrim(cf.itm_name),''''), nullif(btrim(sf.n),''''), p.pname) itm_name,'
    || '            public.item_category(sf.co, sf.med) cat,'
    || '            tt.total_stock stock, tt.total_target target, tt.surplus returnable,'
    || '            p.vendor, p.last_bill_no bill_no, p.last_pth, p.last_bill bill_date, p.bought_qty, p.last_price,'
    || '            least(tt.surplus, p.bought_qty)::int ret_qty,'
    || '            round(coalesce(p.last_price,0) * least(tt.surplus, p.bought_qty))::numeric ret_value,'
    || '            p.back_qty'
    || '       from pur p'
    || '       join tot tt on tt.itm_code = p.itm_code and tt.surplus > 0'
    || '       left join consumption_flat cf on cf.code = p.itm_code'
    || '       left join stock_flat sf on sf.itm_code = p.itm_code'
    || '      where coalesce($8, false)'
    || '         or coalesce(p.back_qty,0) <= 0'
    || '         or coalesce(p.back_qty,0) < least(tt.surplus, p.bought_qty)'
    || ' )'
    || ' select jsonb_build_object('
    || '   ''total_count'', (select count(*) from t),'
    || '   ''total_value'', (select coalesce(sum(ret_value),0) from t),'
    || '   ''rows'', coalesce(('
    || '       select jsonb_agg(to_jsonb(x) order by x.returnable desc, x.ret_value desc nulls last, x.itm_code)'
    || '       from (select * from t order by returnable desc, ret_value desc nulls last, itm_code limit $5 offset $6) x'
    || '   ), ''[]''::jsonb))';

  execute v_sql into v_out
    using p_branch, p_vendor, p_from, p_to, p_limit, p_offset, p_category, p_show_returned;
  return coalesce(v_out, jsonb_build_object('total_count',0,'total_value',0,'rows','[]'::jsonb));
end
$function$;

create function public.get_purchase_surplus_return(
  p_branch text, p_vendor text, p_from date, p_to date,
  p_limit integer, p_offset integer, p_category text default null,
  p_show_returned boolean default false)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select public.get_purchase_surplus_return_impl(
           public.purchase_branch_scope(p_branch, 'purchase_invoices'),
           p_vendor, p_from, p_to, p_limit, p_offset, p_category, p_show_returned);
$function$;

/* الصلاحيات: الاستدعاء للمستخدم المسجّل بس — الدوال _impl مقفولة
   (تغيير البصمة بيضيّع الجرانت، والذاتي بيدّي execute تلقائي فمحتاج revoke صريح) */
revoke all on function public.get_purchase_expiry_review_impl(text,text,date,date,integer,boolean) from public, anon;
revoke all on function public.get_purchase_surplus_return_impl(text,text,date,date,integer,integer,text,boolean) from public, anon;
revoke all on function public.get_purchase_expiry_review(text,text,date,date,integer,boolean) from public, anon;
revoke all on function public.get_purchase_surplus_return(text,text,date,date,integer,integer,text,boolean) from public, anon;
grant execute on function public.get_purchase_expiry_review(text,text,date,date,integer,boolean) to authenticated, service_role;
grant execute on function public.get_purchase_surplus_return(text,text,date,date,integer,integer,text,boolean) to authenticated, service_role;

commit;
