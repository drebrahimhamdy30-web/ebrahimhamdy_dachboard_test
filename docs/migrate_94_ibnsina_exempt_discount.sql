/* ═══════════════════════════════════════════════════════════════════
   خصم الأصناف المعفاة عند ابن سينا — فارما ثم تقريب الشريحة
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   بورتال ابن سينا بيدّي `pharmacyPrice` **غلط للأصناف المعفاة من
   الضريبة** — أقل من المدفوع فعلًا، فالمخزن يبان أرخص مما هو.

   الأدلة (2026-10-04):
   • فاتورة 2026112748548 سطر بسطر: الخمس سطور اللي عليها ضريبة سعرها
     = pharmacyPrice × 1.14 **بالمليم**. والسطرين اللي ضريبتهم صفر
     البورتال قال 27.00 و37.13 والحقيقي 33.00 و39.375.
   • 25 فاتورة: اللي كل سطورها عليها ضريبة اتوازنت 5 من 5، واللي فيها
     سطر بضريبة صفر اتوازنت 1 من 20.
   • 99 صنف قورنوا بفواتير eplus: تكلفتنا مظبوطة في 12 بس، وبنقلّلها
     في 77، بمتوسط مبالغة 2.81 نقطة في الخصم.

   ⚠️ **مش خلل في حساب الضريبة عندنا** (دقته 96%) — سعر المورّد نفسه
      غلط من عنده للمعفى. اتجرّب 6 طرق لاستنتاج الصح (الكارتة الحيّة ·
      oldPrice · البونص · إجماع السوق · الاحتمالية · القرب من الوسيط)
      وكلها فشلت.

   ── القاعدة (قرار المالك) ────────────────────────────────────────
   خصومات ابن سينا وفارما **شرائح ثابتة** — أكّدها تصدير 1,227 صنف من
   فواتير eplus: 20% (536) · 25% (347) · 15% (107) · 18% (97) ·
   12% (38) · 9% (19) · 10% (16) — السبعة دول 95% من الأصناف.

   للأصناف **المعفاة فقط**:
     1. موجود في فارما      →  ياخد خصم فارما (نفس منظومة الخصم)
     2. مش موجود            →  تقريب **لأقل** شريحة
   والأصناف **الخاضعة ما بتتلمسش** — سعر البورتال فيها صح (×1.14).

   أمثلة التقريب:  38.64% → 25%  ·  23% → 20%  ·  19.5% → 18%
   وتحت 9% (أقل شريحة) **بيفضل زي ما هو** بقرار المالك — التقريب لصفر
   كان هيخلّي أصناف تبان غالية ونسيب مورّد أرخص بالغلط.

   ⚠️ خصم فارما موثوق لأن أسعاره بتتوازن مع الفواتير، فبياخد كما هو
      ومابيتقرّبش — **إلا** لو طلع فوق أعلى شريحة (لقينا صنف بـ100%
      كان هيخلّي سعر ابن سينا صفر ويكسب الأرخصية) فساعتها بيتقرّب.

   ── النتيجة المقيسة (السحابة، 2026-10-04) ───────────────────────
   14,776 صنف · 6,016 اتغيّر خصمه بمتوسط −3.57 نقطة (أي التكلفة طلعت
   للحقيقة). المصدر: 2,009 من فارما · 5,526 بالتقريب · 6,841 خاضعة
   مستنتجة · 341 من فواتير حقيقية.
   في الطلبيات المعلّقة: 46 صف سابت ابن سينا كأرخص مورّد (وصفر كسبه)،
   وتكلفتهم الحقيقية عنده 10,358 مقابل 9,645 عند الأرخص الجديد —
   **713 جنيه كانوا هيتصرفوا غلط** في لقطة واحدة.

   ── الأداء ──────────────────────────────────────────────────────
   أول نسخة كانت بنداءات متداخلة لكل صف → `57014 statement timeout`
   على دفعة 500 صف. القراءات بقت `left join` بتتعمل مرة واحدة بالهاش،
   مع فهرس مركّب `(store, code)`.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── سلّم الشرائح — قابل للتعديل من غير كود ───────────────────── */
create table if not exists public.ibnsina_tier_ladder (
  tier numeric primary key
);

insert into public.ibnsina_tier_ladder (tier)
values (9), (10), (12), (15), (18), (20), (25)
on conflict (tier) do nothing;

alter table public.ibnsina_tier_ladder enable row level security;
revoke all on public.ibnsina_tier_ladder from anon, public;
drop policy if exists ibnsina_tier_ladder_auth on public.ibnsina_tier_ladder;
create policy ibnsina_tier_ladder_auth on public.ibnsina_tier_ladder
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.ibnsina_tier_ladder to authenticated;
grant all on public.ibnsina_tier_ladder to service_role;

/* بحث خصم فارما بالكود جوه المزامنة — بدون الفهرس ده الدفعة بتتعلّق */
create index if not exists idx_sip_store_code
  on public.store_item_prices (store, code) where code is not null;

/* ── المزامنة ───────────────────────────────────────────────────── */
create or replace function public.ibnsina_prices_upsert(p_key text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare n_up int; n_guessed int; n_known int; n_g_taxed int; n_ph int; n_snap int;
begin
  if not public.is_ibnsina_sync_key(p_key) then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  create temp table _isn on commit drop as
  with incoming as (
    select distinct on (btrim(item_name))
      btrim(item_name) as item_name, public_price, pharmacy_price,
      nullif(btrim(supplier_code), '') as supplier_code
    from jsonb_to_recordset(p_rows)
      as x(item_name text, public_price numeric, pharmacy_price numeric, supplier_code text)
    where coalesce(btrim(item_name),'') <> '' and public_price > 0 and pharmacy_price > 0
    order by btrim(item_name), pharmacy_price asc
  ),
  cur as (   /* كودنا للصنف — من صفّه الحالي في الكتالوج */
    select sp.item_name, sp.code from store_item_prices sp
      join incoming i on i.item_name = sp.item_name
     where sp.store = 'ابن سينا'
  ),
  ph as (    /* خصم فارما لكل كود — تجميعة واحدة مش نداء لكل صف */
    select sp.code, max(sp.discount_perc) d_pharma from store_item_prices sp
     where sp.store = 'فارما اوفر سيز' and sp.code is not null and sp.discount_perc > 0
     group by sp.code
  ),
  j as (
    /* d_taxed من غير قص عشان السالب يفضل بائن — القص بيغش قاعدة الروندة */
    select i.*, t.taxed, c.code as our_code, p.d_pharma,
           (1 - (i.pharmacy_price * 1.14) / i.public_price) * 100 as d_taxed,
           (1 -  i.pharmacy_price          / i.public_price) * 100 as d_exempt
      from incoming i
      left join ibnsina_tax t on t.supplier_code = i.supplier_code
      left join cur c on c.item_name = i.item_name
      left join ph  p on p.code      = c.code
  ),
  d as (
    select j.*,
           coalesce(j.taxed, j.d_taxed >= 0 and abs(j.d_taxed - round(j.d_taxed)) < 0.03) as is_taxed
      from j
  ),
  s as (
    select d.*,
           (select max(l.tier) from ibnsina_tier_ladder l where l.tier <= d.d_exempt) as snapped,
           /* خصم فارما بياخد كما هو — إلا لو شاذ فوق أعلى شريحة */
           case when d.d_pharma > (select max(tier) from ibnsina_tier_ladder)
                then (select max(l.tier) from ibnsina_tier_ladder l where l.tier <= d.d_pharma)
                else d.d_pharma end as d_ph
      from d
  )
  select item_name, public_price, supplier_code,
         (taxed is null) as guessed, is_taxed,
         case when is_taxed then 'taxed' when d_ph is not null then 'pharma' else 'snap' end as src,
         case
           /* الخاضع: سعر البورتال صح، نضرب الضريبة وخلاص */
           when is_taxed then round(pharmacy_price * 1.14, 4)
           /* المعفى + موجود في فارما: ناخد خصم فارما */
           when d_ph is not null then round(public_price * (1 - d_ph / 100), 4)
           /* المعفى + مش في فارما: تقريب لأقل شريحة.
              وتحت أقل شريحة بيفضل زي ما هو. */
           else round(public_price * (1 - coalesce(snapped, d_exempt) / 100), 4)
         end as net
    from s;

  with up as (
    insert into store_item_prices (item_name, store, price, discount_perc, available, supplier_code, notes, updated_at)
    select item_name, 'ابن سينا', public_price,
           greatest(0, least(100, round((1 - net / public_price) * 100, 2))),
           true, supplier_code,
           case when src = 'pharma' then 'معفى — الخصم من فارما'
                when src = 'snap'   then 'معفى — الخصم مقرّب لأقل شريحة'
                when not guessed    then null
                else                     'ضريبة مستنتجة: خاضعة 14%' end,
           now()
    from _isn
    on conflict (item_name, store) do update
      set price = excluded.price,
          discount_perc = excluded.discount_perc,
          supplier_code = coalesce(excluded.supplier_code, store_item_prices.supplier_code),
          notes = excluded.notes,
          updated_at = now()
    returning 1
  )
  select count(*) into n_up from up;

  select count(*) filter (where guessed),
         count(*) filter (where not guessed),
         count(*) filter (where guessed and is_taxed),
         count(*) filter (where src = 'pharma'),
         count(*) filter (where src = 'snap')
    into n_guessed, n_known, n_g_taxed, n_ph, n_snap
    from _isn;

  return jsonb_build_object(
    'upserted',        n_up,
    'tax_unknown',     n_guessed,
    'from_invoices',   n_known,
    'inferred_taxed',  n_g_taxed,
    'exempt_pharma',   n_ph,
    'exempt_snapped',  n_snap
  );
end
$fn$;

grant execute on function public.ibnsina_prices_upsert(text, jsonb) to anon, authenticated;
