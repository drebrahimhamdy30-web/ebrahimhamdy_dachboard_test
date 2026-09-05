-- ═══════════════════════════════════════════════════════════════════
-- منع إعادة تعيين / نقل طلب اتسلّم خلاص
-- ═══════════════════════════════════════════════════════════════════
-- الحادثة (2026-08-26، السحابة):
--   طلب 1455537 اتسلّم 17:56 بواسطة «مصطفي علاء» على رحلة cc519e14.
--   الرحلة اتقفلت 18:12. الساعة 18:21 اتعيّن **تاني** لـ«احمد ماهر»
--   عن طريق manual_assign_order، فحصل التالي:
--     • السطر اللي بيشيل الربط القديم فكّ الطلب من رحلته الأصلية
--       (الرحلة بقت طلب واحد بدل اتنين)
--     • الطلب اتنسب لطيار **مسلّمهوش**، والـ670 ج كاش اللي حصّلها
--       مصطفي علاء اتسجّلت على أحمد ماهر → تسوية الشيفت بتبوظ
--     • أحمد ماهر «سلّمه» تاني 18:37 بـ0 ج (ومسجّل مرتين — ضغط مزدوج)
--
-- ليه الفحص هنا مش في المتصفح:
--   شاشة التوزيع **بتخفي الأزرار فعلًا** (نقل = assigned/picked بس،
--   تعيين = pending/postponed بس). بس قرارها مبني على نسخة ممكن تكون
--   قديمة — الطيار بيسلّم من موبايله والشاشة لسه ما اتحدّثتش، فالزر
--   بيفضل ظاهر. الدالتين دول هما **الوحيدين** اللي شايفين الحالة
--   الحقيقية لحظة الكتابة.
--
-- ليه مش تريجر:
--   التريجر هيقع على كل كتابة على orders — يشمل مزامنة n8n وتطبيق
--   الطيار وهو بيسلّم. ده خطر على شغل الطيارين. الدالتين دول أصلًا
--   البوابة الوحيدة للتعيين، فالفحص فيهم مغطّي من غير أي أثر جانبي.
--
-- النطاق: delivered + completed بس.
--   ⚠️ failed **مش** ممنوع عن قصد — طلب رجّعه الطيار لازم يتعاد تعيينه.
--   ⚠️ cancelled كمان مسموح — سيبناه لحد ما نراجع مسار الإلغاء لوحده.
--
-- ⚠️ فخّ: CREATE OR REPLACE FUNCTION **بيمسح** خصائص الدالة اللي مش
--    مكتوبة صريح في الأمر — ومنها SET search_path. وده على دالة
--    SECURITY DEFINER ثغرة تصعيد صلاحيات، وكل الدوال الشبيهة عندنا
--    (cleanup_empty_trips / recompute_trip_total) عليها search_path=public.
--    عشان كده مكتوب صريح تحت في الاتنين. الصلاحيات (proacl) بتفضل
--    زي ما هي — بس الخصائص لأ.
--
-- ⚠️ يتشغّل على **الاتنين**: سحابة rxtjoqulmgkkcohmgzgi + سيرفر
--    supabase.ebrahimhamdy.com — القاعدتين لازم يفضلوا متطابقين.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1) manual_assign_order — تعيين طلب واحد
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manual_assign_order(
  p_order_id uuid, p_driver_id uuid, p_user_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public          -- ⚠️ لازم صريح: CREATE OR REPLACE بيمسحه
AS $function$
DECLARE
  v_driver drivers%ROWTYPE;
  v_order  orders%ROWTYPE;
  v_trip_id uuid;
  v_trip_status text;
  v_now timestamptz := now();
BEGIN
  PERFORM public.require_app_role(array['admin','manager','employee','cashier']);

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الطلب غير موجود');
  END IF;

  -- ⛔ طلب اتسلّم خلاص مايتعيّنش تاني (شوف رأس الملف للحادثة).
  --    الفحص قبل أي حاجة تانية عشان يبقى أول باب يتقفل.
  IF v_order.status IN ('delivered','completed') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'الطلب اتسلّم خلاص'
      || COALESCE(' الساعة ' || to_char(v_order.delivered_at AT TIME ZONE 'Africa/Cairo', 'HH24:MI'), '')
      || COALESCE(' بواسطة ' || v_order.deliveryman, '')
      || ' — مايتعيّنش تاني. لو الشاشة لسه شايّاه معلّق، اعمل تحديث.');
  END IF;

  SELECT * INTO v_driver FROM drivers WHERE id = p_driver_id AND is_active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الطيار غير موجود أو معطّل');
  END IF;

  -- امنع فقط لو الطلب على رحلة حيّة فعلاً (نشطة أو بانتظار الإنهاء)
  IF EXISTS (
    SELECT 1 FROM trip_orders tr JOIN trips t ON t.id = tr.trip_id
    WHERE tr.order_id = p_order_id AND t.status IN ('active','pending_complete')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'الطلب موجود بالفعل في رحلة نشطة');
  END IF;

  -- شيل أي ربط قديم متبقٍّ لرحلة مقفولة/منتهية (قيد order_id الفريد لازم يتفكّ قبل الإضافة)
  DELETE FROM trip_orders tr USING trips t
  WHERE tr.trip_id = t.id AND tr.order_id = p_order_id
    AND t.status NOT IN ('active','pending_complete');

  PERFORM set_config('app.manual_assign', 'on', true);

  -- دوّر على أي رحلة مفتوحة للطيار (نشطة أو بانتظار الإنهاء) عشان ما نعملش رحلة تانية بالتوازي.
  -- نفضّل النشطة، وإلا نرجّع رحلة الإنهاء المعلّقة لنشطة (لأن فيه طلب جديد فالرحلة لسه مكمّلة)
  SELECT id, status INTO v_trip_id, v_trip_status
  FROM trips
  WHERE driver_id = p_driver_id AND status IN ('active','pending_complete')
  ORDER BY (status = 'active') DESC, created_at DESC
  LIMIT 1;

  IF v_trip_id IS NULL THEN
    INSERT INTO trips (driver_id, driver_name, branch_id, status, orders_count, total_amount, created_at)
    VALUES (p_driver_id, v_driver.full_name, v_order.branch_id, 'active', 0, 0, v_now)
    RETURNING id INTO v_trip_id;

    INSERT INTO trip_logs (trip_id, event, details, user_name)
    VALUES (v_trip_id, 'trip_created', jsonb_build_object('driver', v_driver.full_name, 'manual', true), p_user_name);
  ELSIF v_trip_status = 'pending_complete' THEN
    -- طلب جديد على رحلة كانت بانتظار الإنهاء → رجّعها نشطة بدل فتح رحلة تانية
    UPDATE trips SET status = 'active', updated_at = v_now WHERE id = v_trip_id;
    INSERT INTO trip_logs (trip_id, event, details, user_name)
    VALUES (v_trip_id, 'trip_reactivated', jsonb_build_object('reason', 'طلب جديد أثناء انتظار الإنهاء', 'manual', true), p_user_name);
  END IF;

  INSERT INTO trip_orders (trip_id, order_id) VALUES (v_trip_id, p_order_id);

  UPDATE orders SET
    driver_id = p_driver_id, deliveryman = v_driver.full_name,
    status = 'assigned', assigned_at = v_now, updated_at = v_now
  WHERE id = p_order_id;

  UPDATE trips SET
    orders_count = (SELECT count(*) FROM trip_orders WHERE trip_id = v_trip_id),
    total_amount = (SELECT COALESCE(sum(o.total_bill_net),0) FROM trip_orders tr JOIN orders o ON o.id = tr.order_id WHERE tr.trip_id = v_trip_id),
    updated_at = v_now
  WHERE id = v_trip_id;

  INSERT INTO order_logs (order_id, event, details, user_name)
  VALUES (p_order_id, 'driver_assigned', jsonb_build_object('driver', v_driver.full_name, 'manual', true, 'trip_id', v_trip_id), p_user_name);

  RETURN jsonb_build_object('success', true, 'trip_id', v_trip_id, 'reactivated', (v_trip_status = 'pending_complete'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END $function$;


-- ───────────────────────────────────────────────────────────────────
-- 2) transfer_orders_to_driver — نقل / إعادة تعيين مجموعة طلبات
-- ───────────────────────────────────────────────────────────────────
-- هنا **مانرفضش الدفعة كلها** لو طلب واحد فيها اتسلّم — نستبعده ونكمّل،
-- ونرجّع أرقامه في skipped عشان الشاشة تقول للموظف اللي حصل. رفض
-- الدفعة كلها كان هيوقف نقل 4 طلبات بسبب واحد اتسلّم في نفس اللحظة.
CREATE OR REPLACE FUNCTION public.transfer_orders_to_driver(
  p_order_ids uuid[], p_to_driver_id uuid, p_reason text, p_user_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public          -- ⚠️ لازم صريح: CREATE OR REPLACE بيمسحه
AS $function$
DECLARE
  v_to_driver drivers%ROWTYPE;
  v_from_driver_id uuid;
  v_from_name text;
  v_new_trip uuid;
  v_new_trip_status text;
  v_old_trip uuid;
  v_now timestamptz := now();
  v_order_id uuid;
  v_moved int := 0;
  v_old_trips uuid[] := '{}';
  v_ids uuid[];          -- الطلبات القابلة للنقل فعلاً
  v_skipped text;        -- أرقام فواتير اللي اتسلّمت خلاص
BEGIN
  PERFORM public.require_app_role(array['admin','manager','employee','cashier']);

  IF p_order_ids IS NULL OR array_length(p_order_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'لم يتم تحديد طلبات');
  END IF;

  -- ⛔ استبعد اللي اتسلّم خلاص (شوف رأس الملف للحادثة).
  --    مسحة واحدة بمفتاح أساسي على عدد طلبات الرحلة (وحدات) — التكلفة
  --    لا تُذكر جنب الـUPDATEات اللي الدالة بتعملها أصلًا.
  SELECT COALESCE(array_agg(o.id) FILTER (WHERE o.status NOT IN ('delivered','completed')), '{}'::uuid[]),
         string_agg(o.bill_no, '، ' ORDER BY o.bill_no) FILTER (WHERE o.status IN ('delivered','completed'))
    INTO v_ids, v_skipped
  FROM orders o
  WHERE o.id = ANY(p_order_ids);

  IF array_length(v_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'الطلب اتسلّم خلاص (' || COALESCE(v_skipped, '—') || ') — مش قابل للنقل. لو الشاشة لسه شايّاه في الشارع، اعمل تحديث.');
  END IF;

  SELECT * INTO v_to_driver FROM drivers WHERE id = p_to_driver_id AND is_active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'الطيار المستلم غير موجود أو معطّل');
  END IF;

  PERFORM set_config('app.manual_assign', 'on', true);

  -- دوّر على أي رحلة مفتوحة للطيار المستلم (نشطة أو بانتظار الإنهاء) عشان ما نعملش رحلة تانية بالتوازي
  SELECT id, status INTO v_new_trip, v_new_trip_status FROM trips
  WHERE driver_id = p_to_driver_id AND status IN ('active','pending_complete')
  ORDER BY (status = 'active') DESC, created_at DESC LIMIT 1;

  IF v_new_trip IS NULL THEN
    INSERT INTO trips (driver_id, driver_name, branch_id, status, orders_count, total_amount, created_at)
    SELECT p_to_driver_id, v_to_driver.full_name, o.branch_id, 'active', 0, 0, v_now
    FROM orders o WHERE o.id = v_ids[1]
    RETURNING id INTO v_new_trip;

    INSERT INTO trip_logs (trip_id, event, details, user_name)
    VALUES (v_new_trip, 'trip_created', jsonb_build_object('driver', v_to_driver.full_name, 'transfer', true), p_user_name);
  ELSIF v_new_trip_status = 'pending_complete' THEN
    UPDATE trips SET status = 'active', updated_at = v_now WHERE id = v_new_trip;
    INSERT INTO trip_logs (trip_id, event, details, user_name)
    VALUES (v_new_trip, 'trip_reactivated', jsonb_build_object('reason', 'نقل طلبات أثناء انتظار الإنهاء', 'transfer', true), p_user_name);
  END IF;

  FOREACH v_order_id IN ARRAY v_ids LOOP
    SELECT o.driver_id, o.deliveryman INTO v_from_driver_id, v_from_name FROM orders o WHERE o.id = v_order_id;

    SELECT tr.trip_id INTO v_old_trip
    FROM trip_orders tr JOIN trips t ON t.id = tr.trip_id
    WHERE tr.order_id = v_order_id AND t.status IN ('active','pending_complete') LIMIT 1;

    IF v_old_trip IS NOT NULL AND NOT (v_old_trip = ANY(v_old_trips)) THEN
      v_old_trips := array_append(v_old_trips, v_old_trip);
    END IF;

    DELETE FROM trip_orders WHERE order_id = v_order_id AND trip_id <> v_new_trip;

    IF NOT EXISTS (SELECT 1 FROM trip_orders WHERE trip_id = v_new_trip AND order_id = v_order_id) THEN
      INSERT INTO trip_orders (trip_id, order_id) VALUES (v_new_trip, v_order_id);
    END IF;

    UPDATE orders SET driver_id = p_to_driver_id, deliveryman = v_to_driver.full_name, status = CASE WHEN status IN ('pending','postponed') THEN 'assigned' ELSE status END, assigned_at = COALESCE(assigned_at, v_now), updated_at = v_now WHERE id = v_order_id;

    INSERT INTO order_logs (order_id, event, details, user_name)
    VALUES (v_order_id, 'order_transferred',
      jsonb_build_object('from', COALESCE(v_from_name, '—'), 'to', v_to_driver.full_name, 'reason', COALESCE(p_reason, '—'), 'trip_id', v_new_trip),
      p_user_name);

    v_moved := v_moved + 1;
  END LOOP;

  UPDATE trips SET
    orders_count = (SELECT count(*) FROM trip_orders WHERE trip_id = v_new_trip),
    total_amount = (SELECT COALESCE(sum(o.total_bill_net), 0) FROM trip_orders tr JOIN orders o ON o.id = tr.order_id WHERE tr.trip_id = v_new_trip),
    updated_at = v_now
  WHERE id = v_new_trip;

  FOREACH v_old_trip IN ARRAY v_old_trips LOOP
    UPDATE trips SET
      orders_count = (SELECT count(*) FROM trip_orders WHERE trip_id = v_old_trip),
      total_amount = (SELECT COALESCE(sum(o.total_bill_net), 0) FROM trip_orders tr JOIN orders o ON o.id = tr.order_id WHERE tr.trip_id = v_old_trip),
      updated_at = v_now
    WHERE id = v_old_trip;

    UPDATE trips SET status = 'completed', updated_at = v_now
    WHERE id = v_old_trip AND NOT EXISTS (SELECT 1 FROM trip_orders WHERE trip_id = v_old_trip);

    INSERT INTO trip_logs (trip_id, event, details, user_name)
    VALUES (v_old_trip, 'orders_transferred',
      jsonb_build_object('to', v_to_driver.full_name, 'count', v_moved, 'reason', COALESCE(p_reason, '—')), p_user_name);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'moved', v_moved, 'trip_id', v_new_trip, 'skipped', v_skipped);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END $function$;
