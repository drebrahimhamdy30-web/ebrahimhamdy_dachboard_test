/* ════════════════════════════════════════════════════════════════
   مراجعة الصيدلي: تقييم الطلب (أخطاء) + تقرير للإدارة
   (2026-11-19)
   ----------------------------------------------------------------
   طلب المالك: خانة في شاشة المراجعة يسجّل فيها الصيدلي الخطأ على
   الطلب اللي قدامه، بأزرار جاهزة وقابلة للزيادة (خطأ تركيز / خطأ
   صنف / نسيان صنف …)، وتقرير يظهر للإدارة بس.

   🔑 **مفيش اختيار لمين غلط** — بقرار المالك: «الطلب ده فيه الصيدلى
   اصلا». يعني النسبة بتتم تلقائيًا على `orders.employee_name`
   (طابع الطلب، وهو الدكتور) — والشاشة أصلًا بتعرضه. فأي خطوة زيادة
   على الصيدلي كانت هتبقى إدخال مكرّر لمعلومة موجودة.

   ── ليه tag واحد بـnote بدل tag لكل نوع خطأ ────────────────────
   الأزرار المخصّصة الموجودة أصلًا بتشتغل كده بالظبط: الزر بيبعت
   driver_note/pharmacy_note والليبل بيتخزّن في note. فلو عملنا tag
   لكل نوع، كل نوع جديد المالك يضيفه هيحتاج تعديل كود — وده بيكسر
   «قابلة للزيادة». فالخطأ كله tag='review_error' ونوعه في note،
   والأزرار بتتقرا من review_buttons زي باقي المخصّصة.

   ⚠️ review_tag_set كانت بتحسب الـaudience كده:
        case when p_tag in ('followup','pharmacy_note') then 'pharmacy'
             else 'driver' end
      يعني أي tag جديد كان هيتخزّن audience='driver' غلط. ضفنا
      'review_error' صراحةً.

   ⚠️ والأخطاء **بتتراكم مش بتتبدّل**: فاتورة ممكن يكون فيها خطأ
      تركيز **و**نسيان صنف. فمفيش delete شامل قبل الإدراج زي
      visa/urgent — بنمنع تكرار **نفس النوع** بس.

   ⚠️ **coalesce في الحارس إلزامي**: jwt_app_role() بترجّع NULL لو
      الكليم مش موجود، و NULL <> 'admin' نتيجتها **NULL مش TRUE** —
      فالحارس بيعدّي أي توكن بلا user_role. اتمسك في اختبار بدور
      pharmacist قبل النشر (migrate_223b على السحابة).
      وjwt_app_role() بتقرا **user_role** مش app_role.

   مافيش جداول جديدة — order_review_tags و review_buttons موجودين.
   يتطبّق على السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── ١) الـRPC تفهم تاج التقييم ──────────────────────────────── */
create or replace function public.review_tag_set(
  p_order_id uuid, p_tag text, p_on boolean,
  p_note text default null, p_user text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $function$
declare
  v_aud text;
  v_ord orders%rowtype;
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

  if p_on then
    /* التاجات دي حالة واحدة للطلب فبتتبدّل. review_error مش منهم:
       الفاتورة ممكن يكون فيها أكتر من خطأ. */
    if p_tag in ('visa','transfer','address_changed','urgent','followup') then
      delete from order_review_tags where order_id=p_order_id and tag=p_tag;
    end if;
    /* نفس نوع الخطأ مرتين على نفس الطلب = ضغطة غلط، مش خطأين */
    if p_tag = 'review_error' then
      delete from order_review_tags
       where order_id=p_order_id and tag='review_error'
         and coalesce(note,'') = coalesce(nullif(p_note,''),'');
    end if;

    insert into order_review_tags(order_id,tag,audience,note,created_by)
    values(p_order_id,p_tag,v_aud,nullif(p_note,''),coalesce(p_user,'مراجع'));

    if p_tag='visa'     then update orders set payment_method='visa',     updated_at=now() where id=p_order_id; end if;
    if p_tag='transfer' then update orders set payment_method='transfer', updated_at=now() where id=p_order_id; end if;
    if p_tag='urgent'   then update orders set notes=case when coalesce(notes,'') like '%🚨%' then notes else '🚨 '||coalesce(notes,'') end, updated_at=now() where id=p_order_id; end if;
    if p_tag='address_changed' then
      update orders set staff_notes = trim(both ' ' from coalesce(staff_notes,'') ||
        case when coalesce(staff_notes,'')='' then '' else ' · ' end ||
        '📍 العنوان اتغيّر'|| case when nullif(p_note,'') is not null then ': '||p_note else '' end),
        updated_at=now() where id=p_order_id;
    end if;
    if p_tag='driver_note' and nullif(p_note,'') is not null then
      update orders set staff_notes = trim(both ' ' from coalesce(staff_notes,'') ||
        case when coalesce(staff_notes,'')='' then '' else ' · ' end || p_note),
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
  end if;

  insert into order_logs(order_id,event,details,user_name)
  values(p_order_id,'order_edited',
    jsonb_build_object('action','review_tag','tag',p_tag,'on',p_on,'note',p_note),
    coalesce(p_user,'مراجع'));

  return jsonb_build_object('success',true);
exception when others then
  return jsonb_build_object('success',false,'error',sqlerrm);
end$function$;

/* ── ٢) الأزرار المبدئية (والمالك يزوّد من الشاشة) ───────────── */
insert into review_buttons(label, audience, is_active, sort_order, created_by)
select v.label, 'review', true, v.ord, 'النظام'
  from (values ('خطأ تركيز',1),('خطأ صنف',2),('نسيان صنف',3),
               ('خطأ كمية',4),('خطأ سعر',5),('خطأ بيانات العميل',6)) as v(label,ord)
 where not exists (
   select 1 from review_buttons b where b.audience='review' and b.label = v.label);

/* ── ٣) تقرير الإدارة ─────────────────────────────────────────
   «من إجمالي طلباته» مش رفاهية: دكتور ٧ أخطاء في ٢٨٠ طلب مش زي
   واحد ٧ في ٣٠. الرقم المطلق لوحده بيظلم أكتر واحد شغّال. */
create or replace function public.get_review_error_report(
  p_from   date default null,
  p_to     date default null,
  p_branch uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_from date; v_to date; v_out jsonb;
begin
  if coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') <> 'service_role'
     and coalesce(public.jwt_app_role(),'') <> 'admin' then
    raise exception 'التقرير ده للإدارة فقط' using errcode = '42501';
  end if;

  v_from := coalesce(p_from, (now() at time zone 'Africa/Cairo')::date - 29);
  v_to   := coalesce(p_to,   (now() at time zone 'Africa/Cairo')::date);

  with ord as (
    select o.id, btrim(o.employee_name) as doctor
      from orders o
     where coalesce(btrim(o.employee_name),'') <> ''
       and (o.created_at at time zone 'Africa/Cairo')::date between v_from and v_to
       and (p_branch is null or o.branch_id = p_branch)
  ),
  tot as (select doctor, count(*)::int as orders_n from ord group by 1),
  err as (
    select o.doctor, coalesce(nullif(btrim(t.note),''),'بدون نوع') as kind
      from order_review_tags t join ord o on o.id = t.order_id
     where t.tag = 'review_error'
  ),
  ek as (select doctor, kind, count(*)::int as k from err group by 1,2),
  ec as (select doctor, sum(k)::int as errors_n, jsonb_object_agg(kind,k) as by_kind
           from ek group by 1)
  select jsonb_build_object(
    'from', v_from, 'to', v_to,
    'kinds', coalesce((select jsonb_object_agg(kind, n)
                         from (select kind, count(*)::int n from err group by 1) q), '{}'::jsonb),
    'total_errors', (select count(*) from err),
    'total_orders', (select count(*) from ord),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'doctor',  t.doctor,
               'orders',  t.orders_n,
               'errors',  coalesce(e.errors_n,0),
               'rate',    case when t.orders_n > 0
                               then round(100.0*coalesce(e.errors_n,0)/t.orders_n, 1) else 0 end,
               'by_kind', coalesce(e.by_kind, '{}'::jsonb))
             order by coalesce(e.errors_n,0) desc, t.orders_n desc)
        from tot t left join ec e on e.doctor = t.doctor), '[]'::jsonb)
  ) into v_out;

  return v_out;
end
$fn$;

revoke all on function public.get_review_error_report(date,date,uuid) from public, anon;
grant execute on function public.get_review_error_report(date,date,uuid) to authenticated;

notify pgrst, 'reload schema';
