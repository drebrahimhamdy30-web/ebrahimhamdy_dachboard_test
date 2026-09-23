-- ═══════════════════════════════════════════════════════════════════
-- حارس: «استلمت» مايشتغلش على طلب مش في رحلة
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-23)
--
-- الحكاية (طلب 1469886 يوم 2026-09-23):
--   1:33 م  الفرع عيّن الطلب لعمر السيد وضافه لرحلته
--   1:37:43 الفرع أجّله → التأجيل شاله من الرحلة وصفّر driver_id
--   1:37:54 تطبيق عمر بعت «استلمت» (استلام جماعي) بعدها بـ11 ثانية
--   النتيجة: status = picked و driver_id = NULL ومش في أي رحلة →
--            الطلب اختفى من كل الشاشات (لا في رحلة ولا في الجاهز).
--
-- الحل: تريجر على orders يرفض الانتقال لـpicked لو الطلب مش في رحلة
-- مفتوحة أو مالوش طيار. بنسيب الصف زي ما هو بدل ما نرمي خطأ، عشان
-- الاستلام الجماعي (UPDATE ... IN (...)) مايفشلش كله بسبب طلب واحد
-- اتشال — الباقي يتسجّل عادي، والمحاولة تتكتب في order_logs.
--
-- الاتصال المباشر (n8n/postgres/service_role) مستثنى زي باقي الحرّاس.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_pick_requires_trip()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_claims text := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '');
  v_driver uuid := coalesce(NEW.driver_id, OLD.driver_id);
  v_trip   uuid;
BEGIN
  -- بنهتم بالانتقال لـpicked بس
  IF NEW.status IS DISTINCT FROM 'picked' OR OLD.status IS NOT DISTINCT FROM 'picked' THEN
    RETURN NEW;
  END IF;

  -- اتصال مباشر أو service_role → عدّي
  IF v_claims = '' OR coalesce(v_claims::jsonb ->> 'role', '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  SELECT t.id INTO v_trip
    FROM trip_orders tox
    JOIN trips t ON t.id = tox.trip_id
   WHERE tox.order_id = NEW.id AND t.status = 'active'
   LIMIT 1;

  IF v_trip IS NOT NULL AND v_driver IS NOT NULL THEN
    RETURN NEW;                                   -- استلام سليم
  END IF;

  -- مش في رحلة (اتأجل/اتلغى/اتشال): نلغي التغيير ونسجّل المحاولة
  INSERT INTO order_logs (order_id, event, user_name, details)
  VALUES (NEW.id, 'pick_blocked', 'حارس الاستلام',
          jsonb_build_object(
            'سبب', CASE WHEN v_trip IS NULL THEN 'الطلب مش في أي رحلة مفتوحة' ELSE 'الطلب مالوش طيار' END,
            'الحالة_قبل', OLD.status, 'driver_id', v_driver));

  NEW.status     := OLD.status;
  NEW.picked_at  := OLD.picked_at;
  NEW.updated_at := OLD.updated_at;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_pick_trip ON public.orders;
CREATE TRIGGER trg_pick_trip
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.trg_pick_requires_trip();

COMMIT;
