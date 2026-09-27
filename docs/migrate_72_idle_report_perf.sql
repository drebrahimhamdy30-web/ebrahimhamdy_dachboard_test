-- ═══════════════════════════════════════════════════════════════════
-- تقارير الطيارين: إصلاح خطأ 500 في get_idle_with_taken (95 ثانية)
-- ═══════════════════════════════════════════════════════════════════
-- الشاشة كانت بترجّع 500 على النداء ده، والسبب مهلة التنفيذ مش صلاحيات:
-- الدالة كانت بتاخد ~95 ثانية على فترة شهر.
--
-- الأسباب التلاتة (اتقاسوا بـEXPLAIN ANALYZE على بيانات سبتمبر 2026):
--   ① الـCTE `sess` (بناء جلسات الحضور من driver_attendance) مكانش
--      متحفوظ، فبيتنفّذ **من الأول لكل حدث سحب طلب** — 4,561 مرة.
--      الحل: `materialized` → يتحسب مرة واحدة. (95 ث → 6.2 ث)
--   ② البحث عن أول picked_at للطيار بعد وقت السحب كان بيستعمل فهرس
--      (driver_id,status) وبيقرا كل طلبات الطيار من القرص:
--      **3.6 مليون قراءة صفحة** في النداء الواحد.
--      الحل: فهرس (driver_id, picked_at).
--   ③ تعبير idle_end (CASE على استعلامين فرعيين) كان بيتكرر في الفلتر
--      والـselect والـhaving والترتيب، فنفس الاستعلامات اتنفّذت ~20 مرة
--      لكل صف. الحل: materialized على inc/inc2/inc3 كمان.
--
-- النتيجة المقاسة: 95,000 مللي ثانية → 673 مللي ثانية (أسرع 141 مرة)،
-- ونفس الـ36 صف بالظبط.
--
-- مفيش أي تغيير في منطق الحساب ولا في الأعمدة اللي بترجع — النتيجة
-- نفسها بالظبط، الفرق في خطة التنفيذ بس.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ① أول picked_at للطيار بعد لحظة معيّنة (تقرير الخمول) + أي تجميع بالطيار/وقت الاستلام
CREATE INDEX IF NOT EXISTS idx_orders_driver_picked
  ON public.orders (driver_id, picked_at);

-- ② أحداث سحب الطلبات: كان بيقرا 77 ألف حدث ويرمي أغلبهم بالفلتر
CREATE INDEX IF NOT EXISTS idx_order_logs_event_created
  ON public.order_logs (event, created_at DESC);

CREATE OR REPLACE FUNCTION public.get_idle_with_taken(p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS TABLE(driver_name text, branch text, incidents integer, max_idle_min integer, details jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with rng as (select (p_from::timestamp at time zone 'Africa/Cairo') t0, ((p_to+1)::timestamp at time zone 'Africa/Cairo') t1),
  ev as (select a.driver_id, a.created_at s, coalesce(a.ended_at,now()) e from driver_attendance a, rng
         where a.status='online' and a.created_at<rng.t1 and coalesce(a.ended_at,now())>rng.t0-interval '1 day'),
  ord as (select ev.*, lag(e) over(partition by driver_id order by s) pe from ev),
  fl as (select ord.*, case when pe is null or s-pe>interval '4 hours' then 1 else 0 end g from ord),
  gp as (select fl.*, sum(g) over(partition by driver_id order by s) grp from fl),
  -- ⚠️ materialized إجباري: من غيرها الـCTE ده بيتنفّذ لكل حدث سحب على حدة
  sess as materialized (select driver_id, min(s) cin, max(e) cout from gp group by driver_id, grp),
  tx as (
    select d.id as driver_id, d.full_name, d.branch, l.created_at as at,
           nullif(l.details->>'trip_id','')::uuid as trip_id, l.details->>'to' as too, l.user_name as by_who
    from order_logs l join drivers d on d.full_name = l.details->>'from', rng
    where l.event='order_transferred' and l.created_at>=rng.t0 and l.created_at<rng.t1
      and (p_branch is null or d.branch_id=p_branch)
  ),
  -- ⚠️ materialized هنا كمان: من غيرها تعبير idle_end بيتكرر في الفلتر
  --    والـselect والـhaving والترتيب، فالاستعلامات الفرعية بتتنفّذ ~20 مرة لكل صف
  inc as materialized (
    select tx.*,
      (select min(o.picked_at) from orders o where o.driver_id=tx.driver_id and o.picked_at>tx.at) as next_pick,
      (select min(s2.cout) from sess s2 where s2.driver_id=tx.driver_id and tx.at>=s2.cin and tx.at<s2.cout) as sess_end
    from tx
  ),
  inc2 as materialized (select inc.*, case when sess_end is null then null when next_pick is null or next_pick>sess_end then sess_end else next_pick end as idle_end from inc),
  inc3 as materialized (select full_name, branch, at, trip_id, too, by_who, round(extract(epoch from (idle_end-at))/60.0)::int as idle_min from inc2 where idle_end is not null and idle_end>at)
  select full_name, branch,
    count(*) filter (where idle_min>=60)::int, max(idle_min),
    jsonb_agg(jsonb_build_object(
      'at',at,'idle_min',idle_min,'to',too,'by',by_who,
      'trip_no', left(inc3.trip_id::text,8),
      'orders',(select jsonb_agg(jsonb_build_object('customer',o.customer_name,'region',o.cust_region,'bill',o.bill_no))
                from trip_orders tr join orders o on o.id=tr.order_id where tr.trip_id=inc3.trip_id)
    ) order by idle_min desc) filter (where idle_min>=60)
  from inc3 group by full_name, branch
  having count(*) filter (where idle_min>=60) > 0
  order by max(idle_min) desc;
$function$;

COMMIT;

ANALYZE public.orders;
ANALYZE public.order_logs;
