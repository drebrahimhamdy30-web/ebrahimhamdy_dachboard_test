/* ════════════════════════════════════════════════════════════════
   المتعلّق يتقفل بتسليم الطيار — من غير تأكيد الصيدلية (2026-10-28)
   ----------------------------------------------------------------
   التصميم الأول كان خطوتين: الطيار يقول «سلّمته» فيبقى «بانتظار
   تأكيد الصيدلية»، والصيدلية تقفله. قرار المالك بعد التجربة:
   **خطوة واحدة** — الطيار وهو بيسلّم الطلب بيتسأل «العميل له مرتجع
   مرفوض، هل تم تسليمه؟»، و«نعم» بتقفل المتعلّق على طول وتسجّل اسم
   الطيار وتاريخ ووقت التسليم.

   السبب اللي خلّى الخطوتين مش محتاجين: السؤال بقى **جوّه مودال
   التسليم** مش زرار منفصل على الكارت — يعني الطيار بيجاوب والحاجة
   في إيده قدام العميل، مش بيفتكر بعدين. الخوف الأصلي (إنه يدوس
   «سلّمته» وهو ناسيه في الصيدلية) اتقفل بمكان السؤال نفسه.

   «لأ» بتفضّله مفتوح وبتزوّد عدّاد المحاولات (كانت وبتفضل كده).

   ⚠️ حالة `delivered_pending` بتفضل في الـcheck constraint: مفيش
   صفوف فيها دلوقتي، بس شيلها من القيد كان هيكسر أي صف قديم لو
   ظهر، والمكسب صفر.

   زر «تأكيد الاستلام» في شاشة العملاء بيفضل (`belonging_confirm`)
   للحالة اللي العميل بيجي الصيدلية وياخد حاجته بنفسه — مفيش طيار
   في الحالة دي أصلًا.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.belonging_mark_delivered(
  p_id bigint, p_order_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_st text; v_bid uuid; v_obid uuid; v_who text;
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;

  select status, branch_id into v_st, v_bid from customer_belongings where id = p_id;
  if v_st is null then raise exception 'المتعلّق غير موجود' using errcode = 'P0002'; end if;
  if v_st = 'confirmed' then raise exception 'مسلَّم بالفعل'  using errcode = '23505'; end if;
  if v_st = 'cancelled' then raise exception 'المتعلّق ملغي'  using errcode = '22023'; end if;

  /* الطيار مش مقصور بفرع في التوكن (التغطية بين الفروع)، فالحارس
     على الطلب نفسه: ماينفعش يسلّم حاجة موجودة في فرع تاني. */
  if p_order_id is not null then
    select branch_id into v_obid from orders where id = p_order_id;
    if v_obid is distinct from v_bid then
      raise exception 'المتعلّق موجود في فرع آخر' using errcode = '42501';
    end if;
  end if;

  v_who := public.belonging_actor();

  /* خطوة واحدة: التسليم هو القفل. الاسم والوقت بيتسجّلوا في
     delivered_* و confirmed_* الاتنين عشان أي تقرير قديم بيقرا
     من أي عمود فيهم يفضل صح. */
  update customer_belongings
     set status       = 'confirmed',
         delivered_at = now(),
         delivered_by = v_who,
         delivered_order_id = coalesce(p_order_id, delivered_order_id),
         confirmed_at = now(),
         confirmed_by = v_who
   where id = p_id;

  return jsonb_build_object('success', true, 'by', v_who);
end $fn$;

revoke all on function public.belonging_mark_delivered(bigint, uuid) from public, anon;
grant execute on function public.belonging_mark_delivered(bigint, uuid) to authenticated;
