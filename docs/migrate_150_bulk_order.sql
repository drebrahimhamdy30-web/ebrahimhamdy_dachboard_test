/* ═══════════════════════════════════════════════════════════════════
   طلبية مجمعة — أعلى الأصناف للفروع الأربعة في طلبية واحدة
   ═══════════════════════════════════════════════════════════════════
   ── الفكرة (قرار المالك) ─────────────────────────────────────────
   نجمّع أعلى الأصناف من الفروع الأربعة في طلبية واحدة كبيرة عشان
   نتفاوض على خصم إضافي. نص في المية على الطلبية دي = ~9 آلاف جنيه.

   ── القواعد المتفق عليها ────────────────────────────────────────
   • الأدوية بس (`stock_flat.med = 1`)
   • الكمية = **المعدل × عدد الشهور** — ومش بتتأثر بالرصيد الحالي
     بالمرّة. المقصود نكبّر الطلبية حتى لو عندنا رصيد.
     (والواقع إن 91 من أعلى 100 رصيدهم أقل من شهر أصلًا.)
   • سعر البيع من **المعمورة** (`m_p`)
   • أرخص سعر **متاح** من أي مخزن — من غير فلتر الفرع
   • الترتيب بالقيمة (معدل × سعر) أو بالمعدل — من الشاشة
   • الشهور وعدد الأصناف من الشاشة

   ── `available = true` شرط مش تفصيلة ───────────────────────────
   أول حساب عملته من غيره طلّع أوجمنتين بخصم 30% من عابدين — وده صف
   سعره القديم (131 بدل 210) والمورّد شايله من الموقع. النتيجة كانت
   تكلفة أقل من الحقيقة بـ**607 ألف جنيه (29%)**، ولو اتفاوضنا بيها
   كنا هنروح برقم مش موجود. الدالة بتاخد المتاح بس.

   ── الأصناف اللي مالهاش مورّد متاح ─────────────────────────────
   **مش داخلة في الـ100** (قرار المالك) — الـ100 كلهم قابلين للطلب
   فعلًا، وبنجيب بدلهم من الترتيب. بس بترجع في `unavailable` لوحدها
   عشان الشاشة تعرضها ورا زرار: 22 صنف بقيمة بيع 918 ألف مالهاش
   مورّد دلوقتي — إشارة مهمة متستخبّاش.

   ⚠️ الحساب كله هنا مش في المتصفح: الترتيب على كل الأصناف والقص
      على الـN المطلوبة لازم يحصل في القاعدة، وإلا سقف الـ1000 صف
      بيقص قبل الترتيب ونطلّع «أعلى 100» من عيّنة عشوائية.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_bulk_order(
  p_limit  integer default 100,
  p_months numeric default 2,
  p_sort   text    default 'value',      -- value | rate
  p_round  text    default 'near'        -- near | up
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
  ranked as (
    select b.*,
           /* أرخص سعر **متاح** من أي مخزن — بلا فلتر فرع */
           s.store, s.discount_perc disc,
           (s.price * (1 - coalesce(s.discount_perc,0)/100))::numeric net
      from base b
      left join lateral (
        select sp.store, sp.price, sp.discount_perc
          from store_item_prices sp
         where sp.code = b.c and sp.available = true and sp.price is not null
         order by sp.price * (1 - coalesce(sp.discount_perc,0)/100) asc
         limit 1) s on true
     where b.rate > 0 and b.price > 0
  ),
  pick as (
    select r.*,
           case when p_round = 'up' then ceil(r.rate * p_months)
                else round(r.rate * p_months) end::int qty
      from ranked r
     where r.store is not null
     order by case when p_sort = 'rate' then r.rate else r.rate * r.price end desc
     limit p_limit
  ),
  /* اللي مالهوش مورّد متاح — بره الـ100 بس بيترجع لوحده.
     بنحدّه بنفس حجم القايمة عشان مايتحوّلش لقايمة تانية طويلة. */
  gone as (
    select r.c, r.nm, r.rate, r.price,
           (round(r.rate * p_months))::int qty
      from ranked r
     where r.store is null
     order by r.rate * r.price desc
     limit p_limit
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
               order by rate*price desc), '[]'::jsonb) from pick),
    'suppliers', (select coalesce(jsonb_agg(x order by (x->>'v')::numeric desc), '[]'::jsonb)
                    from (select jsonb_build_object('n',store,'i',count(*),'v',round(sum(qty*net),2)) x
                            from pick group by store) q),
    'unavailable_count', (select count(*) from gone),
    'unavailable_sale',  (select coalesce(round(sum(qty * price),2),0) from gone),
    'unavailable', (select coalesce(jsonb_agg(jsonb_build_object(
                      'c',c,'n',nm,'r',round(rate::numeric,1),'p',round(price::numeric,2),'qty',qty)
                      order by rate*price desc), '[]'::jsonb) from gone)
  ) into v_out;

  return v_out;
end
$fn$;

revoke all on function public.get_bulk_order(integer, numeric, text, text) from public, anon;
grant execute on function public.get_bulk_order(integer, numeric, text, text) to authenticated, service_role;
