/* ═══════════════════════════════════════════════════════════════════
   سعر ابن سينا من فواتير eplus بدل البورتال
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة (اتكشفت 2026-10-04 من ملاحظة المالك) ────────────────
   بورتال ابن سينا بيدّي `pharmacyPrice` **غلط للأصناف المعفاة من
   الضريبة** — دايمًا أقل من المدفوع فعلًا، فابن سينا يبان أرخص مما هو
   ويكسب مقارنة «أرخص مخزن» بالغلط.

   الأدلة بالترتيب:
   1. مقارنة فاتورة بفاتورة (فاتورة 2026112748548):
        5 سطور عليها ضريبة  → السعر = pharmacyPrice × 1.14 **بالمليم**
        2 سطر ضريبتهم صفر   → البورتال 27.00 و37.13 · الحقيقي 33.00 و39.375
   2. فحص 25 فاتورة: اللي كل سطورها عليها ضريبة اتوازنت 5 من 5،
      واللي فيها سطر بضريبة صفر اتوازنت 1 من 20.
   3. تصدير فواتير eplus (3,177 سطر · 1,227 صنف) أثبت إن خصومات ابن
      سينا **شرائح ثابتة**: 20% (520 صنف) · 25% (322) · 15% (102) ·
      18% (93) · 12% (36) · 9% (19) · 10% (15) — و**96.5% ≤ 25%**.
      بينما البورتال بيوصل بيها 38% و41%.
   4. مقارنة 99 صنف: تكلفتنا مظبوطة في 12 بس، و**بنقلّلها في 77**،
      بمتوسط مبالغة **2.81 نقطة** في الخصم.

   ⚠️ مش مشكلة في حساب الضريبة بتاعنا (ده دقته 96%) — **سعر المورّد
      نفسه غلط من عنده** للأصناف المعفاة.

   ── الحل ─────────────────────────────────────────────────────────
   `ibnsina_real_price` = سعر الشراء الفعلي المسجّل في eplus، وهو
   **يقين** لأنه اللي اتدفع. و`ibnsina_prices_upsert` بتفضّله على
   الحساب المشتق كل ما كان موجود.

   المصدر: تصدير فواتير المورّد من eplus (شاشة الموردين) → يترفع من
   «مقارنة الأسعار». يتكرر كل شهر فالتغطية بتكبر مع كل طلبية.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.ibnsina_real_price (
  code       text primary key,       -- كودنا إحنا (نفس كود eplus)
  buy_price  numeric not null,       -- س.شراء الفعلي شامل الضريبة
  sell_price numeric not null,       -- س.البيع (سعر الجمهور وقت الفاتورة)
  updated_at timestamptz not null default now()
);

alter table public.ibnsina_real_price enable row level security;
revoke all on public.ibnsina_real_price from anon, public;
drop policy if exists ibnsina_real_price_auth on public.ibnsina_real_price;
create policy ibnsina_real_price_auth on public.ibnsina_real_price
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.ibnsina_real_price to authenticated;
grant all on public.ibnsina_real_price to service_role;

/* ── رفع دفعة من الشاشة ──────────────────────────────────────────
   بتاخد [{code, buy, sell}] وبترجّع عدد اللي اتسجّل. محمية بالدور. */
create or replace function public.ibnsina_real_price_upsert(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare n int;
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);

  with up as (
    insert into public.ibnsina_real_price (code, buy_price, sell_price, updated_at)
    select btrim(x.code), x.buy, x.sell, now()
      from jsonb_to_recordset(p_rows) as x(code text, buy numeric, sell numeric)
     where coalesce(btrim(x.code),'') <> '' and x.buy > 0 and x.sell > 0
    on conflict (code) do update
      set buy_price = excluded.buy_price,
          sell_price = excluded.sell_price,
          updated_at = now()
    returning 1
  )
  select count(*) into n from up;

  return jsonb_build_object('saved', n,
    'total', (select count(*) from public.ibnsina_real_price));
end
$fn$;

revoke all on function public.ibnsina_real_price_upsert(jsonb) from public, anon;
grant execute on function public.ibnsina_real_price_upsert(jsonb) to authenticated, service_role;
