/* ============================================================
   تقرير الجرد: شرط التاريخ يسمح بالفهرس
   ------------------------------------------------------------
   الشرط كان مكتوب على **تحويل** العمود:
     (audited_at at time zone 'Africa/Cairo')::date >= p_from::date
   وأي تعبير على العمود بيمنع الفهرس تمامًا، فكل نداء كان بيقرا
   الجدول كله (٣٦ ألف صف) ويحوّل التوقيت لكل صف.

   الشكل الجديد بيقارن العمود نفسه بحدود محسوبة مرة واحدة: بداية
   اليوم بتوقيت القاهرة، ولآخر يوم بنقارن بأول اليوم اللي بعده
   (أصغر من). مكافئ بالظبط — اتأكدت بعدّ الصفوف بالشرطين على نفس
   الفلتر: ٥,٩٩٩ = ٥,٩٩٩.

   + فهرس (branch, audited_at desc) بيغطي الفلتر والترتيب مع بعض.

   النتيجة: الفلترة بقت Index Only Scan في **٤ م.ث** بدل مسح كامل.
   ⚠️ الزمن الكلي اتحسّن شوية بس (170→159 م.ث) لأن الباقي بناء JSON
   لكل صف بيترجع (٦ آلاف صف هنا). تقليله الحقيقي محتاج ترقيم صفحات
   في الشاشة — مش تعديل قاعدة.
   ============================================================ */
create index concurrently if not exists idx_jard_branch_audited
  on public.jard_audit_log (branch, audited_at desc);

create or replace function public.get_jard_full_report(
  p_branch text, p_category text, p_from text, p_to text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'itm_name_ar', itm_name_ar, 'itm_name_en', itm_name_en,
      'category', category, 'matched', matched,
      'system_qty', system_qty, 'actual_qty', actual_qty,
      'audited_by', audited_by,
      'audited_at', to_char(audited_at at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI'),
      'resolved', resolved, 'resolved_by', resolved_by,
      'resolved_at', to_char(resolved_at at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI'),
      'review_qty', review_qty, 'review_sys_qty', review_sys_qty,
      'exp_ym', exp_ym, 'exp_date', to_char(exp_date,'YYYY-MM-DD')
    ) order by audited_at desc), '[]'::jsonb)
  from jard_audit_log
  where (p_branch   is null or p_branch   = '' or branch   = p_branch)
    and (p_category is null or p_category = '' or category = p_category)
    and (p_from is null or p_from = '' or
         audited_at >= ((p_from::date)::timestamp at time zone 'Africa/Cairo'))
    and (p_to   is null or p_to   = '' or
         audited_at <  (((p_to::date + 1))::timestamp at time zone 'Africa/Cairo'));
$function$;

revoke all on function public.get_jard_full_report(text, text, text, text) from public, anon;
grant execute on function public.get_jard_full_report(text, text, text, text) to authenticated, service_role;
