/* ═══════════════════════════════════════════════════════════════════
   عمود «أفضل مورّد» على purchase_orders_flat — للفلترة سيرفر-سايد
   ═══════════════════════════════════════════════════════════════════
   شاشة طلبيات الأدوية بتحمّل من purchase_orders_flat بترقيم على السيرفر،
   و«أفضل مورّد» (أقل سعر شراء من فواتير الشراء) كان بيتجاب لكل صفحة من
   best_purchase_by_code — فمينفعش نفلتر بيه على كل الأصناف.

   الحل: نضيف عمود نصّي واحد (best_pur_store) على الجدول ونملأه بعد كل
   refresh من best_purchase_by_code. عمود **نصّي** بالذات عشان محرّك
   get_purchase_orders بيطلّع الأعمدة غير المحسوبة كـ`null` بلا نوع
   (= text)، فعمود نصّي بيطابقه بلا تعديل في المحرّك (عمود رقمي كان بيكسره).
   السعر نفسه بيتعرض في الشاشة من best_purchase_by_code زي ما هو.
   الشاشة تفلتر بـ best_pur_store=ilike.*قيمة* سيرفر-سايد، والإكسل يتبع الفلتر.

   يتطبّق على: السحابة **و** السيرفر الذاتي.  بعده: select refresh_purchase_orders();
   ═══════════════════════════════════════════════════════════════════ */

alter table public.purchase_orders_flat drop column if exists best_pur_price;
alter table public.purchase_orders_flat add column if not exists best_pur_store text;

create or replace function public.refresh_purchase_orders()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  n      int;
  v_cols text;
begin
  if coalesce(current_setting('request.jwt.claims', true),'') <> '' then
    perform public.require_app_role(array['admin','manager','pharmacist']);
  end if;

  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'purchase_orders_flat'
     and column_name <> 'id';

  truncate purchase_orders_flat;
  execute 'insert into purchase_orders_flat (' || v_cols || ')'
       || ' select ' || v_cols || ' from public.get_purchase_orders()';
  get diagnostics n = row_count;

  /* أفضل مورّد (أقل سعر شراء من فواتير الشراء) — للفلترة سيرفر-سايد في شاشة الأدوية */
  update purchase_orders_flat p
     set best_pur_store = bpc.price_store
    from best_purchase_by_code bpc
   where bpc.itm_code = p.itm_code;

  return n;
end $function$;

/* قائمة الموردين المميّزين (أفضل مورّد) — لتعبئة الفلتر في الشاشة */
create or replace function public.get_order_best_suppliers()
returns setof text language sql stable security definer set search_path to 'public' as $$
  select distinct best_pur_store from purchase_orders_flat
  where best_pur_store is not null and btrim(best_pur_store) <> ''
  order by 1;
$$;
grant execute on function public.get_order_best_suppliers() to anon, authenticated;

select public.refresh_purchase_orders() as rows_built;
notify pgrst, 'reload schema';
