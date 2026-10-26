/* ============================================================
   سجل الشيفتات: صافي الزيادة/العجز على الفترة كلها
   ------------------------------------------------------------
   المالك طلب يشوف صافي العجز أو الزيادة في السجل.

   ⚠️ الإجمالي **لازم ييجي من السيرفر**: السجل مقسّم صفحات على
   السيرفر (٣٠ صف)، فجمع الصفحة المعروضة كان هيدّي رقمًا ناقصًا
   من غير ما حد ياخد باله — القاعدة العامة: المجاميع على كل البيانات
   المفلترة مش على الصفحة.

   بترجّع ٣ أرقام بدل واحد عشان «صافي صفر» ما يخفيش زيادة كبيرة
   قابلت عجزًا كبيرًا:
     total_diff = الصافي · total_up = إجمالي الزيادة · total_down = إجمالي العجز

   مثال حقيقي (المعمورة، أكتوبر ٢٠٢٦): ١٤٦ شيفت، الصافي −٢٣٬٣١١
   وهو حصيلة زيادة ٦١٬٠٠٠ وعجز ٨٤٬٣١١ — الرقمان المنفصلان بيحكوا
   القصة اللي الصافي لوحده بيخبّيها.

   (معادلة diff نفسها اتصلّحت في migrate_159 لتطابق eplus.)
   ============================================================ */

create or replace function public.get_shift_log(
  p_branch text, p_cashier integer default null,
  p_from date default null, p_to date default null,
  p_limit integer default 30, p_offset integer default 0
) returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
  with s as (
    select sc_id, cashier_id, point_name, shift_start, closed_at,
           round(coalesce(start_cash,0)) opening,
           round(coalesce(curr_cash,0))  system_cash,
           round(coalesce(act_cash,0))   actual_cash,
           round(coalesce(trans_value,0)) transfer,
           round(coalesce(curr_cash,0) - coalesce(start_cash,0)) period,
           round((coalesce(curr_cash,0) - coalesce(start_cash,0)) - coalesce(act_cash,0)) diff
      from shift_changes
     where (p_branch is null or branch = p_branch)
       and (p_cashier is null or cashier_id = p_cashier)
       and (p_from is null or closed_at::date >= p_from)
       and (p_to   is null or closed_at::date <= p_to)
  )
  select jsonb_build_object(
    'total_count', (select count(*) from s),
    'total_diff',  (select coalesce(sum(diff),0) from s),
    'total_up',    (select coalesce(sum(diff) filter (where diff > 0),0) from s),
    'total_down',  (select coalesce(sum(diff) filter (where diff < 0),0) from s),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.closed_at desc)
                      from (select * from s order by closed_at desc limit p_limit offset p_offset) x), '[]'::jsonb));
$function$;
