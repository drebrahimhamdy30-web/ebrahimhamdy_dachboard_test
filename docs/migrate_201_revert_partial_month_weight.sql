-- migrate_201_revert_partial_month_weight.sql
--
-- رجوع عن ترجيح الشهر الجاري (migrate_197) بقرار المالك 2026-11-10.
--
-- السبب: الوزن (0.317 في 10 نوفمبر) صح لصنف له تاريخ — بيمنع الشهر
-- الناقص إنه ينزّل المعدل. لكن لما **كل** مبيعات الفرع في الشهر الناقص،
-- القسمة على 0.317 بتضاعف الرقم ٣.١٥ مرة من دليل عشر أيام:
--
--   نوريفين سيرم (89999613) — سيدى بشر: باع 2 في نوفمبر بس
--     المعدل = 2 ÷ 0.317 = 6.3 في الشهر
--
-- الحجم وقت الرجوع (أصناف شهرها النشط الوحيد هو الجاري):
--   السيوف 351 (19.2% من أصنافه) · سيدى بشر 160 (2.2%)
--   سان ستيفانو 116 (1.1%) · المعمورة 115 (0.9%)
-- وفي سيدى بشر وحده: مجموع المعدلات 548 والمفروض 172 — يعني 376
-- وحدة طلب وهمية في الشهر.
--
-- الرجوع: الوزن يرجع 1 دايمًا ⇒ المقام = actp + 1 = act، والبسط = المجموع
-- ⇒ المعادلة ترجع «المجموع ÷ الشهور النشطة» زي ما كانت قبل 197.
--
-- ⚠️ ده رجوع مؤقت. الحساب الأصلي محفوظ تحت الـreturn — شيل السطر
-- وهيرجع يشتغل. والحل المقترح (حد أدنى للمقام = شهر كامل) لسه
-- معروض على المالك: greatest(actp + curw, 1).

create or replace function public.current_month_weight()
returns numeric
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  c_min constant numeric := 0.20;
  v_cur text := public.current_sales_month();
  v_mk  timestamp;
  v_m0  timestamp;
  v_w   numeric;
begin
  /* ═══ رجوع 2026-11-10: الشهر الجاري يتحسب شهر كامل ═══
     شيل السطر ده عشان الترجيح الجزئي يرجع يشتغل. */
  return 1;

  select (max(updated_at)) at time zone 'Africa/Cairo'
    into v_mk
    from public.monthly_sales
   where month = v_cur;

  if v_mk is null then return 0; end if;
  if to_char(v_mk, 'MM-YYYY') <> v_cur then return 0; end if;

  v_m0 := date_trunc('month', v_mk);
  v_w  := extract(epoch from (v_mk - v_m0))
        / extract(epoch from ((v_m0 + interval '1 month') - v_m0));

  if v_w < c_min then return 0; end if;
  return least(v_w, 1);
end $function$;
