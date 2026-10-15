/* ═══════════════════════════════════════════════════════════════════
   طلب الصنف من فرع تاني لقرب انتهاء صلاحيته
   ═══════════════════════════════════════════════════════════════════
   ── الفكرة (قرار المالك) ─────────────────────────────────────────
   لما فرع يطلب صنف، لو فرع تاني عنده منه رصيد صلاحيته قربت **وهو مش
   هيبيعه قبل التاريخ**، نطلبه منه بدل ما نشتري — والفرع المصدر ياخد
   ملاحظة تقوله يبعت التشغيلة دي بالذات.

   ── شرط الترشيح ─────────────────────────────────────────────────
       الكمية القريبة  >  معدل الفرع المصدر × الشهور الفاضلة

   مافيهاش رقم ثابت تحطه بالإيد وبتظبط نفسها: صنف معدله 5 وعنده 3
   هيخلّصها في أقل من شهر → مايظهرش. نفس الصنف بـ40 قطعة وقدامه
   شهرين → يظهر.

   ⚠️ المعدل من `consumption_flat` (المصدر الموحّد) — ممنوع أي حساب
      معدل جديد هنا.

   ── الخصم تلقائي زي الفائض (قرار المالك) ────────────────────────
   `net_required` بيتخصم منه **الأكبر** من: فائض الفروع التانية، أو
   الكمية قريبة الصلاحية. **مش مجموعهم** — التحويلة بتيجي من فرع
   واحد، وجمعهم كان هيفترض إن الصنف هييجي من مصدرين في نفس الوقت.
   ولو نفس الفرع عنده الاتنين، الأكبر بيمنع العدّ المزدوج.

   ── مصدر البيانات ───────────────────────────────────────────────
   `item_expiry` بيتملا من eplus (`Item_Class_Store`) — الرصيد
   المتبقي لكل صنف×فرع×تاريخ صلاحية. بيتخزّن اللي خلال 12 شهر وله
   رصيد موجب (~4,775 صف للفروع الأربعة) وبيتحدّث يوميًا.

   ⚠️ **الربط بـeplus 61% بس** (6,695 من 10,958 في المعمورة) — فيه
      أصناف عندنا مالهاش مقابل هناك. فالعمود الفاضي معناه **يا مفيش
      صلاحية قريبة يا إحنا مش لاقيين الصنف** — والشاشة لازم تفرّق
      بينهم وإلا المشتريات تطمن غلط.

   ── الأثر المقيس وقت الكتابة ────────────────────────────────────
   176 سطر هيظهر فيها العمود · 205 قطعة تتحوّل بدل ما تتشترى ·
   ~34,600 جنيه.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

alter table public.purchase_orders_flat
  add column if not exists exp_branch text,
  add column if not exists exp_qty    integer,
  add column if not exists exp_date   date;

comment on column public.purchase_orders_flat.exp_branch is
  'الفرع اللي عنده رصيد قريب الصلاحية ومش هيبيعه — أقرب تاريخ أولًا. NULL = مفيش مرشّح.';
comment on column public.purchase_orders_flat.exp_qty is 'الكمية المتاحة عند الفرع ده بالتاريخ ده.';
comment on column public.purchase_orders_flat.exp_date is 'تاريخ انتهاء التشغيلة — بيروح في ملاحظة طلب التحويل.';

/* ── الدالة: ترشيح الفرع المصدر ─────────────────────────────────
   أقرب تاريخ أولًا (الأخطر)، وعند التساوي الكمية الأكبر. */
create or replace function public.expiry_source_for(p_branch text, p_code text)
returns table (branch text, qty numeric, exp_date date)
language sql
stable
as $fn$
  select e.branch, e.qty, e.exp_date
    from public.item_expiry e
    left join public.consumption_flat cf on cf.code = e.itm_code
   where e.itm_code = p_code
     and e.branch <> p_branch
     and e.qty > coalesce(
           case e.branch
             when 'المعمورة'     then cf.av_mamora
             when 'سان ستيفانو'  then cf.av_san
             when 'سيدى بشر'     then cf.av_bishr
             when 'السيوف'       then cf.av_seyouf
           end, 0) * greatest(0.5, (e.exp_date - current_date) / 30.0)
   order by e.exp_date asc, e.qty desc
   limit 1
$fn$;

revoke all on function public.expiry_source_for(text, text) from public, anon;
grant execute on function public.expiry_source_for(text, text) to authenticated, service_role;
