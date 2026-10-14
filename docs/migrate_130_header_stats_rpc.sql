/* ============================================================
   عدّادات الهيدر: نداء واحد بدل تلاتة
   ------------------------------------------------------------
   الشل بيحدّث العدّادات كل ٦٠ ثانية بتلات نداءات منفصلة لنفس الجدول
   (جاهز / على رحلة / متأخر). مع كل متصفح مفتوح ده ٤٣٢٠ نداء في اليوم.
   دلوقتي نداء واحد بيمسح الطلبات المفتوحة مرة واحدة ويرجّع التلاتة.

   ⚠️ SECURITY INVOKER بقصد (مش DEFINER): لازم حارس الصلاحيات على
   جدول الطلبات يفضل شغّال زي ما هو، فموظف الفرع يشوف فرعه بس —
   بالظبط زي النداءات التلاتة القديمة. DEFINER هنا كان هيسرّب كل
   الفروع لكل الموظفين.

   الشرط `status in (...)` إيجابي عشان فهرس (status, bill_date) يشتغل؛
   الخمس حالات دي هي **كل** الحالات المفتوحة، والمقفولة (completed /
   cancelled / delivered) مش داخلة في أي عدّاد من التلاتة أصلًا.
   ============================================================ */
create or replace function public.get_header_stats(p_late_minutes integer default 30)
returns jsonb
language sql
stable
security invoker
set search_path to 'public'
as $$
  select jsonb_build_object(
    'pending', count(*) filter (where status = 'pending'),
    'picked',  count(*) filter (where status = 'picked'),
    'late',    count(*) filter (where bill_date < now() - make_interval(mins => greatest(p_late_minutes,0)))
  )
  from public.orders
  where status in ('pending','assigned','picked','postponed','failed');
$$;

revoke all on function public.get_header_stats(integer) from public, anon;
grant execute on function public.get_header_stats(integer) to authenticated;
