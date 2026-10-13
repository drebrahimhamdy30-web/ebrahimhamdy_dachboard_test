/* ═══════════════════════════════════════════════════════════════════
   نقطة الطلب لكل فرع×تصنيف بدل رقم عام واحد
   ═══════════════════════════════════════════════════════════════════
   ── اللي كان متّبع ───────────────────────────────────────────────
   دالة `req_qty(rate, stock, mn, ratio)` فيها **قاعدتين**، والفاصل
   بينهم المعدل مش الرصيد:

     الصنف البطيء (معدل ≤ mn = 3):
         نطلب أول ما الرصيد ينزل **تحت المعدل** (عتبة 100%)،
         والكمية = المعدل − الرصيد. ولو الفرق قرّب لصفر والرصيد أقل
         من واحدة → نطلب 1.

     الصنف السريع (معدل > 3):
         مانطلبش غير لما الرصيد ينزل **لنص المعدل أو أقل**
         (ratio = 0.5)، والكمية = المعدل − الرصيد بحد أدنى 1.

   والصنف اللي معدله صفر أو فاضي مابيتطلبش خالص.

   ⚠️ الرقمين (`min_immediate` و`reorder_ratio`) كانوا في
      `purchase_settings` **صف واحد لكل المؤسسة** — الكوزمو والورقيات
      والأدوية في الأربع فروع كلهم على نفس العتبة. و79% من سطور
      الطلبية (2,894 من 3,684) ماشية بقاعدة «اطلب تحت المعدل».

   ── اللي بقى ────────────────────────────────────────────────────
   العمودين بقوا في `branch_calc_settings` جنب `min_stock_surplus` —
   لكل فرع×تصنيف. و**NULL معناها «خُد العام»**، فالسلوك الحالي هو
   الافتراضي لكل الصفوف ومفيش حاجة بتتغيّر لحد ما المالك يعدّل صف.

   نفس نمط `min_stock_surplus` الموجود أصلًا في نفس الدالة:
       coalesce(g_<فرع>.min_stock_surplus, (select mss from cfg))

   ⚠️ التعديل على `get_purchase_orders` بالاستبدال النصّي — الدالة
      ديناميكية (بتتبني من `branch_letters()` وأعمدة الجدول) و6 آلاف
      حرف، فنسخها يدويًا مخاطرة أكبر من تعديل سطر. وفيه حارس بيرفع
      خطأ لو النص اتغيّر ومالقاش مكان الإضافة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

alter table public.branch_calc_settings
  add column if not exists reorder_ratio numeric,
  add column if not exists min_immediate numeric;

comment on column public.branch_calc_settings.reorder_ratio is
  'نقطة الطلب للصنف السريع كنسبة من المعدل (0.5 = نطلب عند نص المعدل). NULL = خُد purchase_settings.reorder_ratio.';
comment on column public.branch_calc_settings.min_immediate is
  'الفاصل بين البطيء والسريع: المعدل اللي لحد عنده نطلب فور النزول تحت المعدل. NULL = خُد purchase_settings.min_immediate.';

/* حارس: نسبة خارج المدى بتكسر الحساب بصمت */
alter table public.branch_calc_settings
  drop constraint if exists branch_calc_settings_reorder_ratio_ck;
alter table public.branch_calc_settings
  add constraint branch_calc_settings_reorder_ratio_ck
  check (reorder_ratio is null or (reorder_ratio > 0 and reorder_ratio <= 1));

alter table public.branch_calc_settings
  drop constraint if exists branch_calc_settings_min_immediate_ck;
alter table public.branch_calc_settings
  add constraint branch_calc_settings_min_immediate_ck
  check (min_immediate is null or min_immediate >= 0);

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc
   where proname = 'get_purchase_orders' and pronamespace = 'public'::regnamespace;

  if position('.min_immediate, mn)' in v_src) > 0 then
    raise notice 'get_purchase_orders فيها الإعداد بالفعل — اتخطّت';
    return;
  end if;

  /* الإعداد لكل فرع×تصنيف من g_<فرع> اللي الدالة بتعمله join أصلًا،
     والرقم العام من cfg كملاذ. */
  v_src := replace(v_src,
    '|| '', floor((select req_qty(b.r_'' || r.code || '', b.q_'' || r.code || '', mn, ratio) from cfg))::int req_'' || r.code',
    '|| '', floor((select req_qty(b.r_'' || r.code || '', b.q_'' || r.code'
    || ' || '', coalesce(g_'' || r.code || ''.min_immediate, mn)'''
    || ' || '', coalesce(g_'' || r.code || ''.reorder_ratio, ratio)) from cfg))::int req_'' || r.code');

  if position('.min_immediate, mn)' in v_src) = 0
     or position('.reorder_ratio, ratio)' in v_src) = 0 then
    raise exception 'نص get_purchase_orders اتغيّر — الترحيل مالقاش مكان الإضافة. عدّلها يدويًا.';
  end if;

  execute 'create or replace function public.get_purchase_orders() returns setof public.purchase_orders_flat '
       || 'language plpgsql as $q$' || v_src || '$q$';
end $$;

revoke all on function public.get_purchase_orders() from public, anon;
grant execute on function public.get_purchase_orders() to authenticated, service_role;
