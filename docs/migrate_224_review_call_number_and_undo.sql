/* ════════════════════════════════════════════════════════════════
   مراجعة الصيدلي: رقم اتصال للطيار + إصلاح إلغاء التاجات
   (2026-11-19)
   ----------------------------------------------------------------
   ١) **رقم للطيار**: المراجع يكتب رقم بديل يظهر للطيار كزر اتصال.
      العمود `orders.driver_call_number` **موجود أصلًا** وتطبيق
      الطيار بيعرضه كـ«📞 رقم من الإدارة»، وشاشة التوزيع بتكتبه من
      زمان (sendDriverCallNumber). فمحتاجين نوصّله من شاشة المراجعة
      بس — مفيش عمود جديد ولا تعديل في تطبيق الطيار.

   ٢) ⛔ **إصلاح الإلغاء** — سؤال المالك: «لو المراجع كتب عاجل أو أي
      حاجة ولغاها، هل بتتلغى؟». الفحص على الكود:
         عاجل      → بيتشال 🚨 من notes            ✅
         فيزا/تحويل → بترجع cash                   ✅
         ملاحظة للطيار   → **النص بيفضل في staff_notes** ❌
         العنوان متغيّر  → **النص بيفضل في staff_notes** ❌
      يعني الشيب بيختفي من شاشة المراجع **والطيار لسه شايف النص**.
      والمراجع مطمّن إنه لغى — وده أسوأ من إنه ما يلغيش أصلًا.
      وده بيشمل **الأزرار المخصّصة** كمان لأنها بتتخزّن driver_note.

      (مفيش بيانات تثبتها: الإلغاء حصل مرة واحدة بس في السجل وكانت
       urgent واتلغت صح. الدليل من الكود، مش من حالة حصلت.)

   الشيل بيتعمل **بالمقطع كامل** مش replace نصّي: staff_notes مقاطع
   مفصولة بـ' · '، فبنفكّها ونشيل المقطع المطابق ونرجّعها. الـreplace
   كان ممكن يقطع نص مقطع تاني لو النصين متشابهين.

   ⚠️ driver_call_number بيتمسح **بس لو لسه بنفس الرقم** اللي المراجع
      كتبه — لو التوزيع غيّره بعد كده، إلغاء المراجع مايدوسش عليه.

   مافيش جداول جديدة. يتطبّق على السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.review_tag_set(
  p_order_id uuid, p_tag text, p_on boolean,
  p_note text default null, p_user text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $function$
declare
  v_aud text;
  v_ord orders%rowtype;
  v_seg text;          -- المقطع اللي اتكتب في staff_notes
  v_num text;          -- الرقم بعد التنضيف
begin
  if auth.role() is distinct from 'authenticated' then
    return jsonb_build_object('success',false,'error','غير مصرح');
  end if;
  select * into v_ord from orders where id=p_order_id;
  if not found then return jsonb_build_object('success',false,'error','الطلب غير موجود'); end if;

  v_aud := case
             when p_tag = 'review_error'                 then 'review'
             when p_tag in ('followup','pharmacy_note')  then 'pharmacy'
             else 'driver'
           end;

  /* المقطع اللي بيتحط في staff_notes — نفس الصياغة في الاتجاهين،
     عشان الشيل يلاقي اللي الإضافة كتبته بالحرف */
  v_seg := case
             when p_tag = 'address_changed'
               then '📍 العنوان اتغيّر' || case when nullif(p_note,'') is not null then ': '||p_note else '' end
             when p_tag = 'driver_note' then nullif(p_note,'')
             else null
           end;

  v_num := nullif(regexp_replace(coalesce(p_note,''), '[^0-9+]', '', 'g'), '');

  if p_on then
    if p_tag in ('visa','transfer','address_changed','urgent','followup','driver_call') then
      delete from order_review_tags where order_id=p_order_id and tag=p_tag;
    end if;
    if p_tag = 'review_error' then
      delete from order_review_tags
       where order_id=p_order_id and tag='review_error'
         and coalesce(note,'') = coalesce(nullif(p_note,''),'');
    end if;

    insert into order_review_tags(order_id,tag,audience,note,created_by)
    values(p_order_id,p_tag,v_aud,
           case when p_tag='driver_call' then v_num else nullif(p_note,'') end,
           coalesce(p_user,'مراجع'));

    if p_tag='visa'     then update orders set payment_method='visa',     updated_at=now() where id=p_order_id; end if;
    if p_tag='transfer' then update orders set payment_method='transfer', updated_at=now() where id=p_order_id; end if;
    if p_tag='urgent'   then update orders set notes=case when coalesce(notes,'') like '%🚨%' then notes else '🚨 '||coalesce(notes,'') end, updated_at=now() where id=p_order_id; end if;
    if p_tag='driver_call' then
      update orders set driver_call_number=v_num, updated_at=now() where id=p_order_id;
    end if;
    if p_tag in ('address_changed','driver_note') and v_seg is not null then
      update orders set staff_notes = trim(both ' ' from coalesce(staff_notes,'') ||
        case when coalesce(staff_notes,'')='' then '' else ' · ' end || v_seg),
        updated_at=now() where id=p_order_id;
    end if;

  else
    if p_tag = 'review_error' then
      delete from order_review_tags
       where order_id=p_order_id and tag='review_error'
         and coalesce(note,'') = coalesce(nullif(p_note,''),'');
    else
      delete from order_review_tags where order_id=p_order_id and tag=p_tag;
    end if;

    if p_tag='visa'     and v_ord.payment_method='visa'     then update orders set payment_method='cash', updated_at=now() where id=p_order_id; end if;
    if p_tag='transfer' and v_ord.payment_method='transfer' then update orders set payment_method='cash', updated_at=now() where id=p_order_id; end if;
    if p_tag='urgent'   then update orders set notes=trim(both ' ' from replace(replace(coalesce(notes,''),'🚨 ',''),'🚨','')), updated_at=now() where id=p_order_id; end if;

    /* 🔴 الجديد: النص بيتشال من staff_notes فعلًا */
    if p_tag in ('address_changed','driver_note') and v_seg is not null then
      update orders
         set staff_notes = nullif(array_to_string(array(
               select s from unnest(string_to_array(coalesce(v_ord.staff_notes,''), ' · ')) s
                where btrim(s) <> btrim(v_seg)), ' · '), ''),
             updated_at = now()
       where id = p_order_id;
    end if;

    /* الرقم بيتمسح بس لو لسه هو هو — مانـدوسش على رقم التوزيع */
    if p_tag='driver_call' and v_num is not null
       and coalesce(v_ord.driver_call_number,'') = v_num then
      update orders set driver_call_number=null, updated_at=now() where id=p_order_id;
    end if;
  end if;

  insert into order_logs(order_id,event,details,user_name)
  values(p_order_id,'order_edited',
    jsonb_build_object('action','review_tag','tag',p_tag,'on',p_on,'note',p_note),
    coalesce(p_user,'مراجع'));

  return jsonb_build_object('success',true);
exception when others then
  return jsonb_build_object('success',false,'error',sqlerrm);
end$function$;

notify pgrst, 'reload schema';
