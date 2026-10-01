/* ═══════════════════════════════════════════════════════════════════
   آخر مستهلكين للمعدل: الحد الأدنى وملخّص المبيعات
   ═══════════════════════════════════════════════════════════════════
   بيكمّل 85→87. بعده كل مكان في السيستم بياخد المعدل والفائض من
   `consumption_flat` (av_ / sur_) اللي بيتحسب من إعدادات المؤسسة.

   • get_min_stock_alerts: بيضيف `sur` جنب `av` لكل فرع، و`cat` للصنف.
     الشاشة بتحسب «اللي الفرع المصدر بيحتفظ بيه» → لازم تستعمل `sur`
     مش `av`، وإلا الفرع الجديد يبان عنده فائض وهمي زي ما كان بيحصل
     في الطلبيات. `av` باقي للعرض (معدل الشراء).

   • get_sales_summary: بيضيف `<الفرع>_av` و`<الفرع>_sur` لكل صنف.
     ده اللي بيخلّي `inventory_management.html` تبطّل تحسب معدل خام
     بنفسها (كانت بتعمل total/active من غير أي معامل) — كانت المصدر
     التالت المختلف للمعدل في السيستم.
     ⚠️ الأعمدة القديمة `_total`/`_active` **اتسابت زي ما هي** لأن
        فيه مستهلكين تانيين عليها؛ الإضافة بس.

   بعد الترحيل:
     select refresh_consumption_rates();
     select refresh_purchase_orders();

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_min_stock_alerts()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_role text := coalesce(public.jwt_app_role(), '');
  v_pg   text := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  v_rows jsonb;
  v_brs  jsonb;
begin
  if v_pg <> 'service_role' and v_role = '' then
    return jsonb_build_object('success', false, 'error', 'لازم تسجّل دخول');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', bl.code, 'name', bl.name, 'letter', bl.letter)
         order by bl.sort_order, bl.name), '[]'::jsonb)
    into v_brs from public.branch_letters() bl;

  with brn as (
    select distinct b.letter, replace(x, 'ي', 'ى') as nm
      from public.branches b,
           unnest(array[b.name] || coalesce(b.aliases, '{}'::text[])) x
     where b.is_active and nullif(btrim(b.letter), '') is not null
  ),
  items as (
    select sl.item_code,
           max(sl.item_name) filter (where nullif(btrim(sl.item_name), '') is not null) as item_name,
           max(sl.item_type) as item_type,
           max(sl.updated_at) as updated_at
      from stock_limit sl
     where sl.item_code is not null
     group by sl.item_code
  ),
  lim as (
    select sl.item_code, n.letter, max(sl.min_stock) as min_stock
      from stock_limit sl
      join brn n on n.nm = replace(btrim(sl.branch), 'ي', 'ى')
     where sl.item_code is not null
     group by sl.item_code, n.letter
  ),
  pend as (
    select os.itm_code, n.letter
      from order_selections os
      join brn n on n.nm = replace(btrim(os.branch), 'ي', 'ى')
     group by os.itm_code, n.letter
  ),
  per_item as (
    select i.item_code, i.item_name, i.item_type, i.updated_at,
           sf.n, sf.u, sf.co, sf.med,
           (select jsonb_object_agg(bl.letter, jsonb_build_object(
                     'name', bl.name,
                     'sort', bl.sort_order,
                     'min',  (select l.min_stock from lim l
                               where l.item_code = i.item_code and l.letter = bl.letter),
                     'qty',  coalesce((to_jsonb(sf) ->> (bl.letter || '_q'))::numeric, 0),
                     'av',   (to_jsonb(cf) ->> ('av_'  || bl.code))::numeric,
                     'sur',  (to_jsonb(cf) ->> ('sur_' || bl.code))::numeric,
                     'pend', exists (select 1 from pend p
                                      where p.itm_code = i.item_code and p.letter = bl.letter)))
              from public.branch_letters() bl) as br
      from items i
      left join stock_flat sf       on sf.itm_code = i.item_code
      left join consumption_flat cf on cf.code     = i.item_code
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.item_code,
           'name', coalesce(nullif(btrim(p.item_name), ''), p.n, p.item_code),
           'unit', p.u, 'company', p.co, 'med', p.med,
           'cat',  public.item_category(p.co, p.med),
           'type', p.item_type,
           'br', p.br,
           'min_m', (p.br -> 'm' ->> 'min')::numeric,
           'min_s', (p.br -> 's' ->> 'min')::numeric,
           'min_b', (p.br -> 'b' ->> 'min')::numeric,
           'qty_m', coalesce((p.br -> 'm' ->> 'qty')::numeric, 0),
           'qty_s', coalesce((p.br -> 's' ->> 'qty')::numeric, 0),
           'qty_b', coalesce((p.br -> 'b' ->> 'qty')::numeric, 0),
           'av_m',  (p.br -> 'm' ->> 'av')::numeric,
           'av_s',  (p.br -> 's' ->> 'av')::numeric,
           'av_b',  (p.br -> 'b' ->> 'av')::numeric,
           'pend_m', coalesce((p.br -> 'm' ->> 'pend')::boolean, false),
           'pend_s', coalesce((p.br -> 's' ->> 'pend')::boolean, false),
           'pend_b', coalesce((p.br -> 'b' ->> 'pend')::boolean, false),
           'updated_at', p.updated_at
         ) order by coalesce(nullif(btrim(p.item_name), ''), p.n)), '[]'::jsonb)
    into v_rows
    from per_item p;

  return jsonb_build_object(
    'success', true,
    'rows', v_rows,
    'branches', v_brs,
    'my_branch', public.jwt_branch(),
    'is_admin', v_role = 'admin',
    'stock_at', (select max(src_max) from stock_flat_meta));
end
$fn$;

create or replace function public.get_sales_summary()
returns jsonb
language plpgsql
as $fn$
declare
  v_sel  text := '';
  v_rows jsonb;
  r      record;
begin
  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      v_sel := v_sel
        || ', sum(ms.'   || quote_ident(r.code) || ') as ' || quote_ident(r.code || '_total')
        || ', count(*) filter (where ms.' || quote_ident(r.code) || ' > 0) as '
        || quote_ident(r.code || '_active');
    else
      v_sel := v_sel
        || ', 0::numeric as ' || quote_ident(r.code || '_total')
        || ', 0::bigint  as ' || quote_ident(r.code || '_active');
    end if;

    v_sel := v_sel
      || ', max(coalesce(cf.' || quote_ident('av_'  || r.code) || ', 0)) as ' || quote_ident(r.code || '_av')
      || ', max(coalesce(cf.' || quote_ident('sur_' || r.code) || ', 0)) as ' || quote_ident(r.code || '_sur');
  end loop;

  execute
    'select coalesce(jsonb_agg(t), ''[]''::jsonb) from ('
    || ' select ms.itm_code, max(ms.itm_name) as itm_name' || v_sel
    || '   from monthly_sales ms'
    || '   left join consumption_flat cf on cf.code = ms.itm_code'
    || '  group by ms.itm_code) t'
    into v_rows;

  return v_rows;
end
$fn$;
