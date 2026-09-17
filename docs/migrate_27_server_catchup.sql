-- ═══════════════════════════════════════════════════════════════════
--  migrate_27 — الحاجات اللي اتعملت على السحابة من غير ملف migration
-- ═══════════════════════════════════════════════════════════════════
--  ظهرت لما قارنّا سكيما السيرفر الذاتي بالبرودكشن (2026-09-17):
--  ٣ دوال وتريجر وعمود موجودين على السحابة ومش في أي ملف في الريبو.
--  التعريفات دي منقولة حرفيًا من البرودكشن بـpg_get_functiondef.
--
--  آمن يتشغّل أكتر من مرة (كله OR REPLACE / IF NOT EXISTS).
--
--  بيغطّي:
--    • driver_attendance.branch_id + stamp_attendance_branch + التريجر
--      → ساعات الطيار تتنسب للفرع اللي اشتغل فيه فعلاً (تغطية الفروع)
--    • change_driver_branch  → نقل طيار لفرع تاني بحراسة دور من السيرفر
--    • prep_return_to_prep   → رجوع الطلب للتحضير (نظام التحضير)
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ── ١) نسب ساعات الحضور للفرع ──────────────────────────────────────
-- من غير العمود ده حساب الحوافز بينسب ساعات التغطية لفرع الطيار الأصلي
ALTER TABLE public.driver_attendance
  ADD COLUMN IF NOT EXISTS branch_id uuid;

CREATE OR REPLACE FUNCTION public.stamp_attendance_branch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.branch_id is null then
    select d.branch_id into new.branch_id from public.drivers d where d.id = new.driver_id;
  end if;
  return new;
end
$function$;

DROP TRIGGER IF EXISTS trg_stamp_attendance_branch ON public.driver_attendance;
CREATE TRIGGER trg_stamp_attendance_branch
  BEFORE INSERT ON public.driver_attendance
  FOR EACH ROW EXECUTE FUNCTION public.stamp_attendance_branch();

-- ── ٢) نقل طيار لفرع تاني (تغطية) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.change_driver_branch(p_driver_id uuid, p_branch_id uuid, p_user_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  caller_role   text := public.jwt_app_role();
  caller_branch text := public.jwt_branch();
  is_svc boolean := coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role';
  v_old_branch text; v_new_branch text; v_bu_id int;
begin
  perform public.require_app_role(array['admin','manager','employee']);

  select branch, branch_user_id into v_old_branch, v_bu_id from public.drivers where id = p_driver_id;
  if not found then
    return jsonb_build_object('success', false, 'error', 'الطيار غير موجود');
  end if;

  select name into v_new_branch from public.branches where id = p_branch_id;
  if v_new_branch is null then
    return jsonb_build_object('success', false, 'error', 'الفرع غير موجود');
  end if;

  -- الموظف: لازم فرعه يكون طرف في النقل (يسحب لفرعه أو يبعت من فرعه)
  if not is_svc and caller_role = 'employee' then
    if caller_branch is distinct from v_old_branch and caller_branch is distinct from v_new_branch then
      return jsonb_build_object('success', false, 'error', 'مسموح لك تنقل طيار من فرعك أو لفرعك فقط');
    end if;
  end if;

  if v_old_branch is distinct from v_new_branch then
    update public.drivers set branch_id = p_branch_id, branch = v_new_branch where id = p_driver_id;
    if v_bu_id is not null then
      update public.branch_users set branch = v_new_branch where id = v_bu_id;
    end if;
  end if;

  return jsonb_build_object('success', true, 'from', v_old_branch, 'to', v_new_branch);
exception when others then
  return jsonb_build_object('success', false, 'error', sqlerrm);
end
$function$;

-- ── ٣) رجوع الطلب للتحضير ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.prep_return_to_prep(p_order_id uuid, p_user_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order orders%rowtype;
  v_now timestamptz := now();
  v_trip uuid;
begin
  perform public.require_app_role(array['admin','manager','employee','cashier','preparer']);
  select * into v_order from orders where id = p_order_id;
  if not found then
    return jsonb_build_object('success', false, 'error', 'الطلب غير موجود');
  end if;
  if v_order.status in ('picked','delivered','completed') then
    return jsonb_build_object('success', false, 'error', 'الطلب اتستلم خلاص من الطيار — مينفعش يرجع للتحضير');
  end if;
  for v_trip in
    select t.id from trip_orders tr join trips t on t.id = tr.trip_id
    where tr.order_id = p_order_id and t.status in ('active','pending_complete')
  loop
    delete from trip_orders where trip_id = v_trip and order_id = p_order_id;
    update trips set
      orders_count = (select count(*) from trip_orders where trip_id = v_trip),
      total_amount = (select coalesce(sum(o.total_bill_net),0)
                      from trip_orders tr join orders o on o.id = tr.order_id
                      where tr.trip_id = v_trip),
      updated_at = v_now
    where id = v_trip;
  end loop;
  update orders set
    prep_done_at = null, status = 'pending',
    driver_id = null, deliveryman = null,
    assigned_at = null, picked_at = null, updated_at = v_now
  where id = p_order_id;
  insert into order_logs (order_id, event, details, user_name)
  values (p_order_id, 'order_edited',
          jsonb_build_object('action','returned_to_prep','reason','رجوع للتحضير — العميل زوّد على الطلب'),
          coalesce(p_user_name, 'المحضّر'));
  return jsonb_build_object('success', true);
exception when others then
  return jsonb_build_object('success', false, 'error', sqlerrm);
end
$function$;

COMMIT;

-- ملحوظة: prep_return_to_prep بتستعمل orders.prep_done_at، فلازم
-- migrate_21_prep_report يكون اتشغّل قبلها.

-- ═══════════════════════════════════════════════════════════════════
--  (إضافة) أعمدة اتضافت على السحابة من غير ملف migration
-- ═══════════════════════════════════════════════════════════════════
--  ظهرت في الجولة التانية من المقارنة: الـmigrations اتطبّقت كلها
--  ولسه 3 جداول أعمدتها مختلفة. التعريفات منقولة من البرودكشن.
BEGIN;

-- نظام التحضير — الدوال في migrate_21 بتقرا الأعمدة دي
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS prep_done_at         timestamptz,
  ADD COLUMN IF NOT EXISTS prep_hold            boolean     DEFAULT false,
  ADD COLUMN IF NOT EXISTS prep_hold_seconds    numeric     DEFAULT 0,
  ADD COLUMN IF NOT EXISTS prep_hold_started_at timestamptz;

-- مفتاح تشغيل التحضير لكل فرع (مقفول افتراضيًا زي البرودكشن)
ALTER TABLE public.dispatch_settings
  ADD COLUMN IF NOT EXISTS prep_required boolean DEFAULT false;

-- تسوية مبيعات الماكينات مع كشف البنك
ALTER TABLE public.wallet
  ADD COLUMN IF NOT EXISTS bank_settled    boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS bank_settled_at timestamptz;

COMMIT;
