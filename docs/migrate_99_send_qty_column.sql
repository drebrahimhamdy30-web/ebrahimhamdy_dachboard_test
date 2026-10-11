/* ═══════════════════════════════════════════════════════════════════
   «الكمية المرسلة» تبقى عمود حقيقي: purchase_orders_flat.send_qty
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   `purchase_orders_flat` جدول **محسوب بالكامل** — المعدل وصافي المطلوب
   والفائض وأرخص مخزن وسعره وخصمه كلهم نتايج بتتبني كل 10 دقايق.
   و«الكمية المرسلة» هي **الرقم الوحيد في الشاشة اللي مش فيه**: كانت
   بتتحسب في المتصفح (`order_send_qty.qty ?? net_required`).

   فالرابط اضطر يجيب **كل** صفوف المخزن + **كل** جدول الكميات ويفلتر
   في المتصفح — وده اللي خلّى فلتر `net_required>0` يقص 101 من 155
   كمية معدَّلة قبل ما حد يشوفها. وتصدير الإكسل لسه بيكتب
   `net_required` ومابيشوفش التعديلات خالص.

   ── الحل ────────────────────────────────────────────────────────
   عمود `send_qty` بيتحسب في `get_purchase_orders` بـ`left join` على
   `order_send_qty` — **نفس النمط الموجود أصلًا** لتجاوز المخزن:

       best_store = coalesce(ov.store, c.bstore_<فرع>)   ← order_store_override
       send_qty   = coalesce(sq.qty,   <صافي المطلوب>)   ← order_send_qty

   ⚠️ **مش تخزين مكرّر.** `order_send_qty` بيفضل مصدر الحقيقة الوحيد
      للتعديل، و`send_qty` نتيجة محسوبة زي باقي أعمدة الجدول. امسح
      التعديل → العمود يرجع لصافي المطلوب في أول إعادة حساب.

   ⚠️ الكرون بيعيد البناء كل 10 دقايق، فالشاشة لازم تعمل **كتابة
      مزدوجة** عند التعديل (PATCH على الصف + upsert على الجدول) زي ما
      `pickWh` بتعمل بالظبط مع تجاوز المخزن — وإلا الرابط اللي بيتعمل
      بعد التعديل بنص دقيقة ياخد الرقم القديم.

   ── إيه اللي بيتغيّر في السلوك ──────────────────────────────────
   مفيش. الرقم اللي الشاشة بتعرضه دلوقتي هو نفسه اللي هيتخزّن — بس
   محسوب على السيرفر بدل المتصفح، فالرابط والإكسل يقدروا يفلتروا عليه.

   ── التعديل على الدالة ──────────────────────────────────────────
   بالاستبدال النصّي مش بإعادة كتابة الدالة كلها — الدالة ديناميكية
   (بتتبني من `branch_letters()` وأعمدة الجدول) و6 آلاف حرف، فنسخها
   يدويًا مخاطرة أكبر من تعديل سطرين. وفيه حارس بيرفع خطأ لو النص
   اتغيّر ومالقاش مكان الإضافة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

alter table public.purchase_orders_flat add column if not exists send_qty integer;

comment on column public.purchase_orders_flat.send_qty is
  'الكمية اللي هتتبعت للمورّد = order_send_qty.qty لو المشتريات عدّلتها، وإلا صافي المطلوب. نتيجة محسوبة — مصدر الحقيقة هو order_send_qty.';

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc
   where proname = 'get_purchase_orders' and pronamespace = 'public'::regnamespace;

  if position('order_send_qty sq' in v_src) > 0 then
    raise notice 'get_purchase_orders فيها العمود بالفعل — اتخطّت';
    return;
  end if;

  /* الربط بجدول الكميات لكل ذراع فرع — جنب ربط تجاوز المخزن */
  v_src := replace(v_src,
    '|| ''     on ov.branch = '' || quote_literal(r.name) || '' and ov.itm_code = c.itm_code''',
    '|| ''     on ov.branch = '' || quote_literal(r.name) || '' and ov.itm_code = c.itm_code'''
    || E'\n      || ''   left join order_send_qty sq'''
    || E'\n      || ''     on sq.branch = '' || quote_literal(r.name) || '' and sq.itm_code = c.itm_code''');

  /* العمود نفسه — v_net هو تعبير صافي المطلوب للفرع الجاري */
  v_src := replace(v_src,
    'when c.column_name = ''net_required''   then v_net',
    'when c.column_name = ''net_required''   then v_net'
    || E'\n        when c.column_name = ''send_qty''       then ''coalesce(sq.qty, '' || v_net || '')::int''');

  if position('order_send_qty sq' in v_src) = 0
     or position('''send_qty''' in v_src) = 0 then
    raise exception 'نص get_purchase_orders اتغيّر — الترحيل مالقاش مكان الإضافة. عدّلها يدويًا.';
  end if;

  execute 'create or replace function public.get_purchase_orders() returns setof public.purchase_orders_flat '
       || 'language plpgsql as $q$' || v_src || '$q$';
end $$;

revoke all on function public.get_purchase_orders() from public, anon;
grant execute on function public.get_purchase_orders() to authenticated, service_role;
