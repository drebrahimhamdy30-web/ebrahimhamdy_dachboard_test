/* ============================================================
   «سجل الشيفتات»: الفرق كان بمعادلة غير معادلة eplus
   ------------------------------------------------------------
   المالك قارن تقرير eplus بشاشتنا فلقى الأرقام مختلفة تمامًا.
   السبب معادلتان مختلفتان:

     eplus  :  زيادة/عجز = (القيمة − الافتتاحية) − ق.الفترة الفعلية
     شاشتنا :  الفرق     =  ق.الفترة الفعلية − القيمة

   يعني كنا بنقارن **حركة فترة** بـ**رصيد إقفال** — كميّتان مختلفتان
   في المعنى والوحدة، وبإشارة مقلوبة كمان.

   ✔ التحقق: حسبت معادلة eplus على نفس الصفوف فطلعت مطابقة لتقرير
   المالك **بالمليم** في السبع تقفيلات:
     ٢٤/١٠ ٠٣:٤٢ → 517.94 · ٠٩:١٧ → 232.96 · ١٨:٢٢ → 2,727.91
     ٢٥/١٠ ٠٣:٣٥ → −3,905.39 · ٠٨:٣٣ → 42.81 · ١٣:١٩ → 966.10
     ١٨:٥٧ → −1,804.62
   بينما معادلتنا كانت بتدّي −732.94 و−3,157.96 … إلخ.

   📌 **ومعنى الأعمدة (اتأكد من البيانات، مش افتراض):**
     • `start_cash` ق.إفتتاحية — العهدة اللي الشيفت بدأ بيها.
     • `curr_cash`  القيمة — رصيد الدرج حسب النظام عند التقفيل.
     • `curr_cash − start_cash` = **ق.الفترة** (حركة الفترة حسب النظام).
     • `act_cash` = **ق.الفترة الفعلية** — حركة الحساب الفعلية خلال
       الفترة. اتأكد بمقارنتها بمجموع حركات `cashier_transactions`:
       طابقت بالظبط في ٥ تقفيلات، والباقي بتفرق بمقدار **تحويل التسليم**
       بالضبط (اللي بيحصل بعد التقفيل السابق وبيقع جوّه النافذة).
       ⚠️ فهي **مش «الفعلي المعدود»** — محدش عدّ فلوس هنا، وعشان كده
       بتطلع سالبة أحيانًا (−2,174.63 يوم ٢٦/١٠).

   التسمية في الواجهة اتصحّحت كمان: «الفعلي المعدود» كانت بتوحي بعدّ
   يدوي مش موجود.
   ============================================================ */

create or replace function public.get_shift_log(
  p_branch text, p_cashier integer default null,
  p_from date default null, p_to date default null,
  p_limit integer default 30, p_offset integer default 0
) returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
  with s as (
    select sc_id, cashier_id, point_name, shift_start, closed_at,
           round(coalesce(start_cash,0)) opening,
           round(coalesce(curr_cash,0))  system_cash,
           round(coalesce(act_cash,0))   actual_cash,
           round(coalesce(trans_value,0)) transfer,
           /* ق.الفترة = القيمة − الافتتاحية */
           round(coalesce(curr_cash,0) - coalesce(start_cash,0)) period,
           /* نفس معادلة eplus بالظبط */
           round((coalesce(curr_cash,0) - coalesce(start_cash,0)) - coalesce(act_cash,0)) diff
      from shift_changes
     where (p_branch is null or branch = p_branch)
       and (p_cashier is null or cashier_id = p_cashier)
       and (p_from is null or closed_at::date >= p_from)
       and (p_to   is null or closed_at::date <= p_to)
  )
  select jsonb_build_object(
    'total_count', (select count(*) from s),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.closed_at desc)
                      from (select * from s order by closed_at desc limit p_limit offset p_offset) x), '[]'::jsonb));
$function$;

/* ── وشاشة تفاصيل الشيفت المقفول ──────────────────────────────
   `get_shift_detail` لسه بترجّع `diff` بالمعادلة القديمة، لكن الشاشة
   **بتتجاهله وبتحسب الرقم بنفسها** من `system_cash` و`opening`
   و`actual_cash` — وكلهم في الرد أصلًا، فالنتيجة واحدة.

   ليه مالمستهاش: جسم الدالة فيه regex بـbackslashes مزدوجة لتمييز
   الفيزا اليدوية، وإعادة كتابته كاملة بالإيد كانت هتخاطر بتغيير
   التصنيف من غير داعي — والتعديل الديناميكي (replace + execute)
   اترفض بصلاحيات التشغيل. التنظيف لاحقًا من غير أي أثر على العرض. */
