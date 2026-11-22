/* migrate_227 — حارس فرع حقيقي للصرف التلقائي (بلاغ المالك 2026-11-22)

   المالك نبّه إن الصرف للمعمورة بس. الفحص أثبت إن ده **مش محروس على
   السيرفر**: enqueue_wallet_disbursement كانت بتفحص الصلاحية والمدفوع
   والمراجعة والصورة والخريطة — ومفيش ولا فحص للفرع.

   اللي كان بيمنع الصرف في بشر وسان حاجتين، ولا واحدة فيهم حارس:
     · DISBURSE_BRANCHES = ['mamora'] في **المتصفح** — إخفاء مش منع.
     · wallet_channel_map فاضية للفروع دي فبترجّع خطأ «مش مربوط».

   يعني الحماية كانت **صدفة إن جدول فاضي**. وأول ما نملا الخريطة — وده
   اللي كنا ناويين نعمله عشان نربط شاشة الأرصدة — الحارس كان هيتشال في
   صمت والصرف يشتغل في التلات فروع.

   الحل: الفروع المسموح لها بالصرف بقت إعداد صريح
   (org_settings.disburse_branches، ابتدأ {mamora})، والدالة بترفض أي
   فرع برّاه برسالة واضحة. قرار مكتوب مش أثر جانبي.

   الاختبار بعد التطبيق:
     bishr / san / seyouf → «الصرف التلقائي غير مفعّل لفرع …»
     mamora              → عدّى الحارس ووقف عند الفحص اللي بعده
   (البصمة c894e14ff53ade8552f5e2de6740619e مطابقة للسحابة.) */

alter table public.org_settings
  add column if not exists disburse_branches text[] not null default array['mamora']::text[];

comment on column public.org_settings.disburse_branches is
  'أكواد الفروع المسموح لها بالصرف التلقائي من نقطة البيع للمحفظة. الحارس على السيرفر في enqueue_wallet_disbursement.';

CREATE OR REPLACE FUNCTION public.enqueue_wallet_disbursement(p_branch text, p_fh_id bigint, p_channel text, p_paid numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_by text; v_exist public.wallet_disbursement_queue; v_map public.wallet_channel_map;
        v_from int; v_bill bigint; v_emp text; v_allowed text[];
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بهذا الإجراء' using errcode = '42501';
  end if;
  /* 🔑 حارس الفرع. قبل كده مكانش فيه، واللي كان بيمنع الصرف في باقي
     الفروع إن wallet_channel_map فاضية ليهم — حماية بالصدفة مش بقرار.
     دلوقتي القرار مكتوب في org_settings.disburse_branches. */
  select o.disburse_branches into v_allowed from public.org_settings o where o.id = 1;
  v_allowed := coalesce(v_allowed, array['mamora']::text[]);
  if not (coalesce(public.branch_code_of(p_branch), p_branch) = any(v_allowed)) then
    return jsonb_build_object('success', false,
      'error', 'الصرف التلقائي غير مفعّل لفرع «' || p_branch || '» — يتفعّل من إعدادات المؤسسة');
  end if;
  if coalesce(p_paid,0) <= 0 then
    return jsonb_build_object('success', false, 'error', 'قيمة المدفوع لازم تكون أكبر من صفر');
  end if;
  if coalesce(trim(p_channel),'') = '' then
    return jsonb_build_object('success', false, 'error', 'الحساب (القناة) غير محدّد');
  end if;
  if not exists (select 1 from shift_txn_reviews r where r.branch = p_branch and r.fh_id = p_fh_id) then
    return jsonb_build_object('success', false, 'error', 'لازم تتراجع الحركة الأول');
  end if;
  if not exists (select 1 from txn_receipts t where t.kind = 'card' and t.branch = p_branch and t.ref_id = p_fh_id::text) then
    return jsonb_build_object('success', false, 'error', 'لا توجد صورة تحويل مرفقة');
  end if;
  select * into v_map from public.wallet_channel_map where branch = p_branch and channel = p_channel and active;
  if not found then
    return jsonb_build_object('success', false, 'error', 'الحساب «' || p_channel || '» مش مربوط بحساب eplus لهذا الفرع — لازم يتضاف للخريطة الأول');
  end if;
  select to_id, sth_id, user_name into v_from, v_bill, v_emp
    from cashier_transactions
    where branch = p_branch and fh_id = p_fh_id and to_type = 3 limit 1;
  if v_from is null then
    return jsonb_build_object('success', false, 'error', 'تعذّر تحديد نقطة البيع المصدر لهذه الحركة');
  end if;
  select * into v_exist from public.wallet_disbursement_queue where branch = p_branch and fh_id = p_fh_id;
  if found then
    return jsonb_build_object('success', true, 'already', true, 'status', v_exist.status, 'queue_id', v_exist.id,
                              'eplus_fh_id', v_exist.eplus_fh_id, 'to_name', v_exist.resolved_to_name);
  end if;
  v_by := public.bank_actor();
  insert into public.wallet_disbursement_queue(branch, fh_id, channel, paid, requested_by,
                                               resolved_to_fcs_id, resolved_to_name, from_fcs_id, bill_no, employee)
    values (p_branch, p_fh_id, p_channel, p_paid, v_by, v_map.fcs_id, v_map.fcs_name, v_from, v_bill, v_emp)
  on conflict (branch, fh_id) do nothing;
  select * into v_exist from public.wallet_disbursement_queue where branch = p_branch and fh_id = p_fh_id;
  return jsonb_build_object('success', true, 'queue_id', v_exist.id, 'status', v_exist.status,
                            'to_name', v_exist.resolved_to_name, 'from_fcs_id', v_exist.from_fcs_id,
                            'bill_no', v_exist.bill_no, 'employee', v_exist.employee, 'account', v_by);
end $function$;

comment on function public.enqueue_wallet_disbursement(text, bigint, text, numeric) is
  'طلب صرف من نقطة البيع لحساب المحفظة في eplus. الحراس بالترتيب: صلاحية المراجعة · الفرع في org_settings.disburse_branches · المدفوع>0 · الحركة متراجَعة · صورة تحويل مرفقة · الحساب مربوط في wallet_channel_map.';
