-- ═══════════════════════════════════════════════════════════════════
-- التحضير: زر «إزالة» — يشيل الطلب من شاشة المحضّر من غير «تم التحضير»
-- ═══════════════════════════════════════════════════════════════════
-- فيه طلبات الصيدلي بيحضّرها بنفسه، وطلبات بتيجي خارج وقت المحضّر.
-- المحضّر مكانش قدامه غير «✓ تم التحضير» عشان يشيلها من شاشته — والضغطة
-- دي بتكتب سجل order_prepared باسمه، وده اللي تقرير التحضير ومؤشر الأداء
-- بيحسبوا منه: فبتزوّد عدد فواتيره وبتدخل في متوسط زمن تحضيره غلط.
--
-- الحل: عمود استثناء مستقل + دالة محروسة.
--   • الطلب **ماتتغيّرش حالته خالص** — لا prep_done_at ولا الحالة ولا
--     الرحلة. الإزالة إخفاء من شاشة التحضير وبس.
--   • بيتكتب سجل `prep_excluded` في order_logs، فيبان في تتبّع الطلب
--     ومعاه اسم اللي شاله — من غير ما يدخل في أي تقرير تحضير.
--   • الصلاحية: المحضّر ومدير الفرع (والأدمن) — محروسة على السيرفر.
--
-- ⚠️ البوابة: لو الفرع مفعّل عنده «التحضير إجباري» (prep_required)،
--    الطلب المستثنى كان هيفضل محجوز للأبد لأن prep_done_at فاضي.
--    عشان كده البوابتين (auto_dispatch_tick / manual_assign_order)
--    بقوا يعتبروا المستثنى مفكوك. دلوقتي prep_required = false في كل
--    الفروع، فالتعديل ده احتياطي لليوم اللي تفعّله فيه.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS prep_excluded_at timestamptz,
  ADD COLUMN IF NOT EXISTS prep_excluded_by text;

COMMENT ON COLUMN public.orders.prep_excluded_at IS
  'اتشال من شاشة التحضير من غير تحضير فعلي (الصيدلي حضّره / خارج وقت المحضّر) — مش «تم التحضير»';

-- ═══ الدالة المحروسة ═══
CREATE OR REPLACE FUNCTION public.prep_exclude_order(p_order_id uuid, p_user_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
declare v_who text; n int;
begin
  perform public.require_app_role(array['admin','manager','preparer']);
  v_who := nullif(btrim(coalesce(p_user_name,'')),'');

  update orders
     set prep_excluded_at = now(),
         prep_excluded_by = coalesce(v_who, 'مستخدم')
   where id = p_order_id
     and prep_excluded_at is null;
  get diagnostics n = row_count;

  if n = 0 then
    return jsonb_build_object('success', false, 'error', 'الطلب مش موجود أو متشال قبل كده');
  end if;

  insert into order_logs (order_id, event, details, user_name)
  values (p_order_id, 'prep_excluded',
          jsonb_build_object('action','excluded_from_prep'),
          coalesce(v_who, 'المحضّر'));

  return jsonb_build_object('success', true);
end $fn$;

-- رجوع الطلب لشاشة التحضير (لو اتشال بالغلط)
CREATE OR REPLACE FUNCTION public.prep_unexclude_order(p_order_id uuid, p_user_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
declare v_who text; n int;
begin
  perform public.require_app_role(array['admin','manager','preparer']);
  v_who := nullif(btrim(coalesce(p_user_name,'')),'');

  update orders set prep_excluded_at = null, prep_excluded_by = null
   where id = p_order_id and prep_excluded_at is not null;
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('success', false, 'error', 'الطلب مش مستثنى أصلًا');
  end if;

  insert into order_logs (order_id, event, details, user_name)
  values (p_order_id, 'prep_unexcluded',
          jsonb_build_object('action','returned_to_prep_list'),
          coalesce(v_who, 'المحضّر'));

  return jsonb_build_object('success', true);
end $fn$;

GRANT EXECUTE ON FUNCTION public.prep_exclude_order(uuid, text)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.prep_unexclude_order(uuid, text) TO authenticated;

-- ═══ البوابتين: المستثنى يتعامل كأنه مفكوك ═══
-- بنعدّل نص الدالة نفسه ونعيد إنشاءها، فمفيش أي حتة تانية بتتغيّر،
-- ولو النص اتغيّر على السيرفر الترحيل بيقع بصوت عالي بدل ما يعدّي صامت.
DO $do$
DECLARE src text; nw text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'auto_dispatch_tick';
  IF src IS NULL THEN RAISE EXCEPTION 'auto_dispatch_tick مش موجودة'; END IF;

  nw := replace(src,
    'AND (NOT COALESCE(s.prep_required, false) OR prep_done_at IS NOT NULL)',
    'AND (NOT COALESCE(s.prep_required, false) OR prep_done_at IS NOT NULL OR prep_excluded_at IS NOT NULL)');
  IF nw = src THEN RAISE EXCEPTION 'مش لاقي شرط التحضير في auto_dispatch_tick'; END IF;
  EXECUTE nw;
END $do$;

DO $do$
DECLARE src text; nw text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'manual_assign_order';
  IF src IS NULL THEN RAISE EXCEPTION 'manual_assign_order مش موجودة'; END IF;

  nw := replace(src,
    'IF v_order.prep_done_at IS NULL' || chr(10) || '     AND EXISTS (SELECT 1 FROM dispatch_settings ds',
    'IF v_order.prep_done_at IS NULL AND v_order.prep_excluded_at IS NULL' || chr(10) || '     AND EXISTS (SELECT 1 FROM dispatch_settings ds');
  IF nw = src THEN RAISE EXCEPTION 'مش لاقي شرط التحضير في manual_assign_order'; END IF;
  EXECUTE nw;
END $do$;

COMMIT;

-- PostgREST لازم يشوف الأعمدة الجديدة عشان الشاشة تفلتر بيها
NOTIFY pgrst, 'reload schema';
