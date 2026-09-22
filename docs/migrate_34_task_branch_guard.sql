-- ═══════════════════════════════════════════════════════════════════
-- حارس: ممنوع طلب بفرع مش مسجّل (جدول task)
-- ═══════════════════════════════════════════════════════════════════
-- (اتطبّق على البرودكشن 2026-09-23)
--
-- السبب: طلب تحويل من 6 سبتمبر اتخزّن وفرعه «جارٍ التحميل…» — دي جملة
-- تحميل من الواجهة اتحفظت مكان اسم الفرع، فالطلب فضل معلّق من غير ما
-- يوصل لأي فرع حقيقي. الصف اتمسح والحارس ده بيمنع تكرارها.
--
-- المسموح في task.branch:
--   • فرع مسجّل في branches (بالاسم أو alias، وفرق ي/ى مايفرقش) —
--     وبيتحوّل تلقائيًا للاسم القياسي.
--   • اسم مستخدم مسجّل في branch_users — الإشعارات وبعض طلبات الشراء
--     بتتبعت لشخص مش لفرع (48 إشعار لـdr-ebrahimhamdy مثلًا).
--   • «عام» و«كل الفروع» — قيم مقصودة موجودة فعلًا.
--   • فاضي/NULL — مابنمنعوش عشان ماناكسرش تدفقات قديمة.
-- وأي حاجة تانية بترفض برسالة واضحة.
--
-- الاتصال المباشر بالقاعدة (n8n/postgres/service_role) مستثنى عشان
-- المزامنات ماتقفش — زي حارس إقفال الفترة بالظبط.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_task_branch_valid()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_claims text := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '');
  b        text := btrim(coalesce(NEW.branch, ''));
  v_canon  text;
BEGIN
  -- اتصال مباشر أو service_role → عدّي
  IF v_claims = '' OR coalesce(v_claims::jsonb ->> 'role', '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF b = '' OR b IN ('عام', 'كل الفروع') THEN
    RETURN NEW;
  END IF;

  -- فرع مسجّل (اسم أو alias) → نخزّن الاسم القياسي
  SELECT br.name INTO v_canon FROM branches br
   WHERE replace(br.name, 'ي', 'ى') = replace(b, 'ي', 'ى')
      OR EXISTS (SELECT 1 FROM unnest(coalesce(br.aliases, '{}')) a
                  WHERE replace(a, 'ي', 'ى') = replace(b, 'ي', 'ى'))
   LIMIT 1;
  IF v_canon IS NOT NULL THEN
    NEW.branch := v_canon;
    RETURN NEW;
  END IF;

  -- اسم مستخدم مسجّل (الإشعارات بتروح لشخص)
  IF EXISTS (SELECT 1 FROM branch_users u WHERE btrim(u.username) = b) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'فرع غير معروف في الطلب: «%» — لازم فرع مسجّل أو مستخدم مسجّل', b
    USING ERRCODE = 'check_violation';
END $fn$;

DROP TRIGGER IF EXISTS trg_task_branch ON public.task;
CREATE TRIGGER trg_task_branch
  BEFORE INSERT OR UPDATE OF branch ON public.task
  FOR EACH ROW EXECUTE FUNCTION public.trg_task_branch_valid();

COMMIT;
