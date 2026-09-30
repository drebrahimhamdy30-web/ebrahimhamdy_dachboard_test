/* ═══════════════════════════════════════════════════════════════════
   ابن سينا: استنتاج الضريبة من السعر بدل افتراض «خاضع» للكل
   ═══════════════════════════════════════════════════════════════════
   المشكلة (اتقاست 2026-10-01):
     كتالوج ابن سينا بيدّي سعر الصيدلية **قبل الضريبة** ومفيش أي حقل
     بيقول الصنف خاضع ولا معفى (اتأكدنا: 11 حقل في الكتالوج مفيهمش
     ضريبة، و`isTaxExempt` في نداء التوفّر راجع false لكل صنف حتى
     مستحضرات التجميل — حقل ميت).
     فكنا بنفترض «خاضع» للكل ونضرب ×1.14. النتيجة: 14,048 صنف من
     14,630 (96%) ضريبتهم مخمّنة، ونص الكتالوج تقريبًا الخصم بتاعه
     بيطلع أقل من الحقيقة بـ~12 نقطة، فابن سينا بيبان أغلى مما هو
     وقرار «أرخص مخزن» بيروح لمورّد أغلى.
     مثال: ابينفرين 100 امبول — جمهور 750، سعرهم 600 (خصم 20% مظبوط)،
     وإحنا كنا بنعرضه 8.8%.

   الضريبة ثنائية مش متدرّجة:
     اتفحصت من مصدرين — خريطة 358 فاتورة (310 صنف خاضع **كلهم 14.00%**)
     وفحص سطر-بسطر على 40 فاتورة (103 سطر: 61 بدون ضريبة، 42 بـ14.00%).
     مفيش ولا نسبة تالتة. فالسؤال «خاضع ولا لأ» مش «النسبة كام».

   القاعدة الجديدة:
     المورّد بيدّي خصم برقم **مدوّر** (20%، 25%، 15%). فبنحسب الخصم
     بافتراض الضريبة، ولو طلع رقم مدوّر يبقى الافتراض صح.
       خاضع  ⟺  (1 − سعرهم×1.14 ÷ الجمهور) رقم مدوّر  **و** مش سالب
     الشرط التاني حارس ضروري: 304 صنف سعرهم بعد الضريبة أغلى من سعر
     الجمهور — دول معفيين قطعًا، والقص عند صفر كان بيخبّيهم ويخلّيهم
     يبانوا «مدوّرين».

   الدقة (مقاسة على 579 صنف ضريبتهم مقطوع فيها من فواتير حقيقية):
     القاعدة الجديدة  559/579 = 96.5%   (251 خاضع صح · 308 معفى صح)
     الافتراض القديم  260/579 = 44.9%
     الغلط الباقي 20 صنف (11 قلناهم خاضع وهما معفى · 9 العكس).

   ⚠️ الفواتير تفضل المرجع الأول: أي صنف في `ibnsina_tax` بياخد قيمته
      منها والقاعدة ماتلمسهوش. القاعدة للباقي بس.

   `notes` بقى بيفرّق التلات حالات عشان تبان في الشاشة:
     NULL → من فاتورة حقيقية · «ضريبة مستنتجة: خاضعة/معفاة» → قاعدة.

   بعد الترحيل لازم تتعاد المزامنة عشان الأسعار تتحسب بالقاعدة الجديدة:
     node tools/ibnsina_pull.js
   (مابنعملش backfill بحساب عكسي — الـ304 المقصوصين عند صفر سعرهم
    الخام اتفقد ومش هيترجع إلا من المصدر.)

   يتطبّق على: السحابة (مزامنة ابن سينا بتكتب هناك).
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.ibnsina_prices_upsert(p_key text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare n_up int; n_guessed int; n_known int; n_g_taxed int;
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
  j as (
    /* d_taxed = الخصم لو الصنف خاضع — **من غير قص** عشان السالب يفضل
       بائن؛ القص عند صفر بيخلّي السالب يبان 0.00 يعني «مدوّر» وبيغش
       القاعدة. */
    select i.item_name, i.public_price, i.pharmacy_price, i.supplier_code,
           t.taxed,
           (1 - (i.pharmacy_price * 1.14) / i.public_price) * 100 as d_taxed
      from incoming i
      left join ibnsina_tax t on t.supplier_code = i.supplier_code
  ),
  d as (
    select j.*,
           coalesce(j.taxed,
                    j.d_taxed >= 0 and abs(j.d_taxed - round(j.d_taxed)) < 0.03
           ) as is_taxed
      from j
  )
  select item_name, public_price, supplier_code,
         (taxed is null) as guessed, is_taxed,
         case when is_taxed then round(pharmacy_price * 1.14, 4)
              else pharmacy_price end as net
    from d;

  with up as (
    insert into store_item_prices (item_name, store, price, discount_perc, available, supplier_code, notes, updated_at)
    select item_name, 'ابن سينا', public_price,
           greatest(0, least(100, round((1 - net / public_price) * 100, 2))),
           true, supplier_code,
           case when not guessed then null
                when is_taxed   then 'ضريبة مستنتجة: خاضعة 14%'
                else                 'ضريبة مستنتجة: معفاة' end,
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
         count(*) filter (where guessed and is_taxed)
    into n_guessed, n_known, n_g_taxed
    from _isn;

  return jsonb_build_object(
    'upserted',        n_up,
    'tax_unknown',     n_guessed,          -- اسم قديم بيستعمله السكربت
    'from_invoices',   n_known,
    'inferred_taxed',  n_g_taxed,
    'inferred_exempt', n_guessed - n_g_taxed
  );
end
$fn$;

/* الصلاحيات زي ما هي: السكربت المحلي بينادي بمفتاح anon والحراسة
   جوّه الدالة بـ is_ibnsina_sync_key — فمابنسحبش execute من anon هنا
   (على عكس دوال فارما اللي بتتنادى بـservice_role من Edge Function). */
grant execute on function public.ibnsina_prices_upsert(text, jsonb) to anon, authenticated;
