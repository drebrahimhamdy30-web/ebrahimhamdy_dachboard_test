-- ═══════════════════════════════════════════════════════════════════
-- المراجعة في التقرير الشامل: المراجع يسجّل الرصيد اللي لقاه
-- ═══════════════════════════════════════════════════════════════════
-- زر «تم» في التقرير الشامل كان بيعلّم الصف «تمّت المراجعة» وبس — من غير
-- ما يتسجّل المراجع لقى كام. فلما يرجع للصنف بعد أسبوع مايعرفش كان الرصيد
-- وقت مراجعته ولا إيه اللي اتصرف فيه.
--
-- بنضيف عمودين على jard_audit_log:
--   review_qty      = الرصيد اللي لقاه **المراجع** وقت المراجعة
--   review_sys_qty  = رصيد النظام لحظة المراجعة (عشان الفرق يتقارن صح؛
--                     رصيد النظام بيتغيّر مع البيع والشراء بعد الجرد)
-- وبيرجّعوا في تقرير الجرد الشامل عشان يظهروا في الشاشة.
--
-- resolve_jard_audit بقت تاخدهم (اختياريين) — النداءات القديمة اللي
-- بتبعت 3 بارامترات بس شغّالة زي ما هي.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.jard_audit_log
  ADD COLUMN IF NOT EXISTS review_qty     numeric,
  ADD COLUMN IF NOT EXISTS review_sys_qty numeric;

COMMENT ON COLUMN public.jard_audit_log.review_qty     IS 'الرصيد اللي لقاه المراجع وقت المراجعة';
COMMENT ON COLUMN public.jard_audit_log.review_sys_qty IS 'رصيد النظام لحظة المراجعة';

CREATE OR REPLACE FUNCTION public.resolve_jard_audit(
  p_id bigint,
  p_by text,
  p_resolved boolean DEFAULT true,
  p_review_qty numeric DEFAULT NULL,
  p_review_sys_qty numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  -- «تمت المراجعة» = دور رقابي للمشرف/الأدمن — موظف الجرد اللى عدّ ماينفعش يراجع لنفسه
  perform public.require_app_role(array['admin','supervisor','reviewer']);
  update jard_audit_log set
    resolved       = p_resolved,
    resolved_by    = case when p_resolved then p_by  else null end,
    resolved_at    = case when p_resolved then now() else null end,
    -- التراجع بيمسح أرقام المراجعة كمان عشان مايفضلش رقم بلا مراجعة
    review_qty     = case when p_resolved then coalesce(p_review_qty,     review_qty)     else null end,
    review_sys_qty = case when p_resolved then coalesce(p_review_sys_qty, review_sys_qty) else null end
  where id = p_id;
end $function$;

-- التقرير الشامل بيرجّع أرقام المراجعة كمان
CREATE OR REPLACE FUNCTION public.get_jard_full_report(p_branch text, p_category text, p_from text, p_to text)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',             id,
      'code',           code,
      'itm_name_ar',    itm_name_ar,
      'itm_name_en',    itm_name_en,
      'category',       category,
      'matched',        matched,
      'system_qty',     system_qty,
      'actual_qty',     actual_qty,
      'audited_by',     audited_by,
      'audited_at',     to_char(audited_at at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI'),
      'resolved',       resolved,
      'resolved_by',    resolved_by,
      'resolved_at',    to_char(resolved_at at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI'),
      'review_qty',     review_qty,
      'review_sys_qty', review_sys_qty
    ) order by audited_at desc), '[]'::jsonb)
  from jard_audit_log
  where (p_branch   is null or p_branch=''   or branch = p_branch)
    and (p_category is null or p_category='' or category = p_category)
    and (p_from is null or p_from='' or (audited_at at time zone 'Africa/Cairo')::date >= p_from::date)
    and (p_to   is null or p_to=''   or (audited_at at time zone 'Africa/Cairo')::date <= p_to::date);
$function$;

GRANT EXECUTE ON FUNCTION public.resolve_jard_audit(bigint,text,boolean,numeric,numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_jard_full_report(text,text,text,text) TO anon, authenticated;

COMMIT;
