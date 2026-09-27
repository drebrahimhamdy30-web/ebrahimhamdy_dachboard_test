-- ═══════════════════════════════════════════════════════════════════
-- التقرير الشامل: إظهار تاريخ الصلاحية اللي كتبه موظف الجرد
-- ═══════════════════════════════════════════════════════════════════
-- لما الصنف يطلع «غير مطابق»، الموظف بيكتب الرصيد الفعلي **وتاريخ
-- الصلاحية** (شهر/سنة) في نفس الشاشة، والقيمة بتتخزّن في jard_audit_log
-- (exp_ym و exp_date). بس تقرير الجرد الشامل مكانش بيرجّعهم، فالمراجع
-- مكانش بيشوف الصلاحية الحقيقية اللي اتسجّلت وقت الجرد.
-- الدالة بقت ترجّعهم، والشاشة بتعرضهم في عمود «الصلاحية».
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

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
      'review_sys_qty', review_sys_qty,
      'exp_ym',         exp_ym,
      'exp_date',       to_char(exp_date,'YYYY-MM-DD')
    ) order by audited_at desc), '[]'::jsonb)
  from jard_audit_log
  where (p_branch   is null or p_branch=''   or branch = p_branch)
    and (p_category is null or p_category='' or category = p_category)
    and (p_from is null or p_from='' or (audited_at at time zone 'Africa/Cairo')::date >= p_from::date)
    and (p_to   is null or p_to=''   or (audited_at at time zone 'Africa/Cairo')::date <= p_to::date);
$function$;

GRANT EXECUTE ON FUNCTION public.get_jard_full_report(text,text,text,text) TO anon, authenticated;

COMMIT;
