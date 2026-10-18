/* ═══════════════════════════════════════════════════════════════════
   الطلبية المجمعة: صف المورّد لازم يكون منطقي + حصر «غير المتاح»
   ═══════════════════════════════════════════════════════════════════
   اتكشفوا الاتنين وقت اختبار migrate_150 على بيانات حقيقية.

   ── ١) صيدلية عمرها ما تشتري بأغلى من سعر البيع ─────────────────
   سعر الدوا مطبوع على العلبة وواحد عند الكل، فأي صف مورّد صافيه
   **أعلى من سعر بيعنا** مش عرض — ده صف وحدة مختلفة أو صنف اسمه
   متشابه.

   وقع فعلًا مع **ميرونيم 1جم**: سعر البيع 553 وصافي الشراء 4,700
   (علبة مقابل فيال). هامش ناقص 750%، والصنف لوحده نزّل هامش
   الطلبية كلها من 22% لـ8%.

   العدد صغير والأثر ضخم: **61 صنف من 6,971** (0.9%) بيضيفوا
   **1.57 مليون** تكلفة وهمية. فالاختيار بقى من الصفوف اللي
   `net < price` بس.

   ── ٢) «غير المتاح» كان قايمة تانية مش استثناء ─────────────────
   كان بيرجّع أعلى 100 صنف بلا مورّد من **الكتالوج كله** — رقم بلا
   معنى. بقى: الأصناف اللي ترتيبها جوّه الـN المطلوبة
   (`rk_all <= p_limit`) ومالهاش مورّد صالح. يعني «دول كانوا هيدخلوا
   طلبيتك ومش قادرين» — 20 صنف بقيمة بيع 859 ألف، مش 100.

   ومعاهم **سبب** مكتوب: «مفيش مورّد متاح» أو «كل أسعاره أعلى من
   سعر البيع» — عشان الفرق بين الحالتين يبان، والتانية غالبًا غلط
   تكويد يستاهل مراجعة مش نقص حقيقي.

   ── بعد التصحيح ────────────────────────────────────────────────
   100 صنف · 14,055 قطعة · شراء 2,220,703 · بيع 2,846,980 ·
   ربح 626,277 (هامش 22%) · الـ0.5% = 11,104 ج ·
   صفر صفقة خاسرة، والهوامش من 3% لـ41%.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_bulk_order(
  p_limit  integer default 100,
  p_months numeric default 2,
  p_sort   text    default 'value',
  p_round  text    default 'near'
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_out jsonb;
begin
  if p_limit  is null or p_limit  < 1 or p_limit  > 1000 then p_limit  := 100; end if;
  if p_months is null or p_months <= 0 or p_months > 12  then p_months := 2;   end if;

  with base as (
    select sf.itm_code c,
           coalesce(nullif(sf.n,''), cf.itm_name) nm,
           sf.co company,
           coalesce(cf.av_mamora,0) + coalesce(cf.av_san,0)
         + coalesce(cf.av_bishr,0)  + coalesce(cf.av_seyouf,0) rate,
           sf.m_p price,
           coalesce(sf.m_q,0) + coalesce(sf.s_q,0)
         + coalesce(sf.b_q,0) + coalesce(sf.f_q,0) stock
      from stock_flat sf
      join consumption_flat cf on cf.code = sf.itm_code
     where sf.med = 1
       and sf.itm_code not in (select itm_code from archived_items)
  ),
  elig as (
    /* الأرخص من الصفوف **المنطقية** بس: متاح، وصافيه أقل من سعر بيعنا.
       و has_any بيفرّق بين «مفيش مورّد خالص» و«فيه بس كله أغلى». */
    select b.*, s.store, s.discount_perc disc,
           (s.price * (1 - coalesce(s.discount_perc,0)/100))::numeric net,
           exists (select 1 from store_item_prices sp
                    where sp.code = b.c and sp.available = true and sp.price is not null) has_any
      from base b
      left join lateral (
        select sp.store, sp.price, sp.discount_perc
          from store_item_prices sp
         where sp.code = b.c and sp.available = true and sp.price is not null
           and sp.price * (1 - coalesce(sp.discount_perc,0)/100) < b.price
         order by sp.price * (1 - coalesce(sp.discount_perc,0)/100) asc
         limit 1) s on true
     where b.rate > 0 and b.price > 0
  ),
  ranked as (
    /* rk_all = ترتيب الصنف بين **كل** الأصناف — عشان نعرف مين كان
       هيدخل الـN لو كان متاح. */
    select e.*,
           case when p_round = 'up' then ceil(e.rate * p_months)
                else round(e.rate * p_months) end::int qty,
           row_number() over (order by case when p_sort = 'rate' then e.rate
                                            else e.rate * e.price end desc) rk_all
      from elig e
  ),
  pick as (
    select * from ranked where store is not null
     order by case when p_sort = 'rate' then rate else rate * price end desc
     limit p_limit
  ),
  gone as (
    select * from ranked where store is null and rk_all <= p_limit
     order by rate * price desc
  )
  select jsonb_build_object(
    'months',  p_months,
    'sort',    p_sort,
    'count',   (select count(*) from pick),
    'pieces',  (select coalesce(sum(qty),0) from pick),
    'cost',    (select coalesce(round(sum(qty * net),2),0) from pick),
    'sale',    (select coalesce(round(sum(qty * price),2),0) from pick),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
               'c',c,'n',nm,'co',company,'r',round(rate::numeric,1),'p',round(price::numeric,2),
               'stock',round(stock::numeric),'qty',qty,'st',store,
               'd',round(coalesce(disc,0)::numeric,1),'nt',round(net,2),
               'cost',round(qty*net,2),'sale',round(qty*price,2))
               order by case when p_sort='rate' then rate else rate*price end desc), '[]'::jsonb) from pick),
    'suppliers', (select coalesce(jsonb_agg(x order by (x->>'v')::numeric desc), '[]'::jsonb)
                    from (select jsonb_build_object('n',store,'i',count(*),'v',round(sum(qty*net),2)) x
                            from pick group by store) q),
    'unavailable_count', (select count(*) from gone),
    'unavailable_sale',  (select coalesce(round(sum(qty * price),2),0) from gone),
    'unavailable', (select coalesce(jsonb_agg(jsonb_build_object(
                      'c',c,'n',nm,'r',round(rate::numeric,1),'p',round(price::numeric,2),'qty',qty,
                      'why', case when has_any then 'كل أسعاره أعلى من سعر البيع'
                                  else 'مفيش مورّد متاح' end)
                      order by rate*price desc), '[]'::jsonb) from gone)
  ) into v_out;

  return v_out;
end
$fn$;

revoke all on function public.get_bulk_order(integer, numeric, text, text) from public, anon;
grant execute on function public.get_bulk_order(integer, numeric, text, text) to authenticated, service_role;
