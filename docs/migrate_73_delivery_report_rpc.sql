-- ═══════════════════════════════════════════════════════════════════
-- شاشة التقارير: الحساب اتنقل للسيرفر (بدل سحب كل الطلبات للمتصفح)
-- ═══════════════════════════════════════════════════════════════════
-- الشاشة كانت بتفتح في ~36 ثانية. السبب: loadReport() كانت بتنزّل **كل**
-- طلبات الفترة بكل أعمدتها (سبتمبر 2026 = 16,115 طلب ≈ 9 ميجا خام) على
-- 17 نداء متسلسل، وبعدين تحسب كل المؤشرات في الجافاسكربت وترسم آلاف
-- الصفوف في الصفحة.
--
-- دلوقتي:
--   • get_delivery_report  → نداء واحد بيرجّع كل المؤشرات محسوبة في
--     القاعدة (jsonb، صف واحد، مش متأثر بسقف الـ1000 صف).
--   • get_delivery_orders  → القوايم (ملغي/متأخر/أداء/تصدير) بتقسيم
--     صفحات على السيرفر: بترجّع صفحة + الإجمالي الحقيقي لكل البيانات.
--
-- ⚠️ فرق مقصود عن القديم: النافذة الزمنية بقت **بتوقيت القاهرة**.
--    القديم كان بيبعت 'YYYY-MM-DDT00:00:00' من غير منطقة زمنية،
--    وPostgREST بيفسّرها UTC — يعني اليوم كان بيبدأ 3 الفجر بتوقيتنا.
--    التجميع اليومي كمان بقى بتاريخ القاهرة مش UTC. الأرقام ممكن
--    تفرق شوية عن قبل — دي الأرقام الصح.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ ① كل مؤشرات الشاشة في نداء واحد ═══
CREATE OR REPLACE FUNCTION public.get_delivery_report(
  p_from date, p_to date, p_branch uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
with rng as (
  select (p_from::timestamp at time zone 'Africa/Cairo') t0,
         ((p_to + 1)::timestamp at time zone 'Africa/Cairo') t1
),
o as materialized (
  select x.id, x.branch_id, x.driver_id, x.status, x.deliveryman, x.customer_name,
         x.cust_region, x.total_bill_net, x.perf_rating, x.sla_rating, x.sla_minutes,
         x.sla_actual_minutes, x.expected_minutes, x.actual_minutes,
         x.distance_meters, x.fail_distance_meters, x.created_at
    from orders x, rng
   where x.created_at >= rng.t0 and x.created_at < rng.t1
     and (p_branch is null or x.branch_id = p_branch)
),
done as (select * from o where status in ('delivered','completed')),
k as (
  select count(*)::int total,
         count(*) filter (where status in ('delivered','completed'))::int completed,
         count(*) filter (where status = 'cancelled')::int cancelled,
         coalesce(sum(total_bill_net) filter (where status in ('delivered','completed')),0)::numeric revenue
    from o
),
daily as (
  select (created_at at time zone 'Africa/Cairo')::date d, count(*)::int n
    from o group by 1
),
st as (select status s, count(*)::int n from o group by 1),
reg as (
  select coalesce(nullif(cust_region,''),'—') r, count(*)::int n
    from o group by 1 order by 2 desc limit 20
),
drank as (
  select deliveryman nm, count(*)::int n, coalesce(sum(total_bill_net),0)::numeric revenue
    from done where coalesce(deliveryman,'') <> '' group by 1 order by 2 desc limit 10
),
pf as (
  select perf_rating k, count(*)::int n from o
   where perf_rating is not null and expected_minutes is not null and actual_minutes is not null
   group by 1
),
rated as (select * from o where sla_rating is not null),
sla_c as (select sla_rating k, count(*)::int n from rated group by 1),
sla_late as (select * from rated where sla_rating = 'متأخر'),
sla_cause as (
  select count(*) filter (where perf_rating = 'متأخر')::int by_driver,
         count(*) filter (where perf_rating is not null and perf_rating <> 'متأخر')::int by_pharmacy,
         count(*)::int late_total
    from sla_late
),
sla_reg as (
  select coalesce(nullif(r.cust_region,''),'—') region,
         coalesce(r.branch_id::text,'') bid,
         coalesce(b.name,'—') branch,
         count(*)::int total,
         count(*) filter (where r.sla_rating = 'متأخر')::int late,
         count(*) filter (where r.sla_rating = 'متأخر' and r.perf_rating = 'متأخر')::int by_driver,
         count(*) filter (where r.sla_rating = 'متأخر' and r.perf_rating is not null and r.perf_rating <> 'متأخر')::int by_pharmacy,
         max(r.sla_minutes)::int sla,
         avg(coalesce(r.sla_actual_minutes,0))::numeric avg_actual
    from rated r left join branches b on b.id = r.branch_id
   group by 1,2,3
  having count(*) filter (where r.sla_rating = 'متأخر') > 0
   order by power(count(*) filter (where r.sla_rating = 'متأخر'), 2) / greatest(count(*),1) desc
   limit 30
),
dstat as (
  select driver_id,
         count(*)::int orders,
         (coalesce(sum(distance_meters),0)/1000.0)::numeric km,
         count(*) filter (where perf_rating is not null)::int ratedn,
         count(*) filter (where perf_rating = 'ممتاز')::int good,
         count(*) filter (where perf_rating = 'جيد')::int ok,
         count(*) filter (where perf_rating = 'متأخر')::int bad,
         (array_agg(deliveryman) filter (where coalesce(deliveryman,'') <> ''))[1] nm
    from done where driver_id is not null group by 1
),
fkm as (
  select driver_id, (coalesce(sum(fail_distance_meters),0)/1000.0)::numeric fail_km
    from o where driver_id is not null and fail_distance_meters is not null group by 1
),
bdone as (select branch_id, count(*)::int n from done where branch_id is not null group by 1),
topc as (
  select coalesce(nullif(customer_name,''),'—') nm, count(*)::int n
    from o where status = 'cancelled' group by 1 order by 2 desc limit 10
),
topl as (
  select coalesce(nullif(customer_name,''),'—') nm, count(*)::int n
    from sla_late group by 1 order by 2 desc limit 10
),
-- مرات تعذّر التوصيل: اللي الطيار سجّلها بنفسه من التطبيق (kept_in_trip)،
-- مش إجراءات اللوحة (إزالة من رحلة / تأجيل يدوي / إرجاع عند إنهاء الرحلة)
pflog as (
  select l.user_name nm
    from order_logs l join orders x on x.id = l.order_id, rng
   where l.event = 'order_postponed'
     and l.created_at >= rng.t0 and l.created_at < rng.t1
     and (l.details -> 'kept_in_trip') = 'true'::jsonb
     and (p_branch is null or x.branch_id = p_branch)
),
faild as (
  select btrim(p.nm) nm, count(*)::int n
    from pflog p
   where coalesce(btrim(p.nm),'') <> ''
     and exists (select 1 from drivers d where btrim(d.full_name) = btrim(p.nm))
   group by 1 order by 2 desc limit 10
)
select jsonb_build_object(
  'kpis', (select jsonb_build_object(
      'total', total, 'completed', completed, 'cancelled', cancelled,
      'revenue', round(revenue),
      'rate', case when total > 0 then round(completed * 100.0 / total) else 0 end,
      'avg_order', case when completed > 0 then round(revenue / completed) else 0 end) from k),
  'daily', coalesce((select jsonb_agg(jsonb_build_object('d', to_char(d,'YYYY-MM-DD'), 'n', n) order by d) from daily), '[]'::jsonb),
  'status', coalesce((select jsonb_agg(jsonb_build_object('s', s, 'n', n) order by n desc) from st), '[]'::jsonb),
  'regions', coalesce((select jsonb_agg(jsonb_build_object('r', r, 'n', n) order by n desc) from reg), '[]'::jsonb),
  'drivers_rank', coalesce((select jsonb_agg(jsonb_build_object('name', nm, 'n', n, 'revenue', round(revenue)) order by n desc) from drank), '[]'::jsonb),
  'perf', jsonb_build_object(
      'total', coalesce((select sum(n) from pf), 0),
      'counts', coalesce((select jsonb_object_agg(k, n) from pf), '{}'::jsonb)),
  'sla', jsonb_build_object(
      'rated', coalesce((select sum(n) from sla_c), 0),
      'counts', coalesce((select jsonb_object_agg(k, n) from sla_c), '{}'::jsonb),
      'cause', (select jsonb_build_object('by_driver', by_driver, 'by_pharmacy', by_pharmacy,
                  'unknown', late_total - by_driver - by_pharmacy, 'late_total', late_total) from sla_cause),
      'regions', coalesce((select jsonb_agg(jsonb_build_object(
                  'region', region, 'bid', bid, 'branch', branch, 'total', total, 'late', late,
                  'by_driver', by_driver, 'by_pharmacy', by_pharmacy, 'sla', sla,
                  'avg', round(avg_actual, 1))) from sla_reg), '[]'::jsonb)),
  'driver_stats', coalesce((select jsonb_agg(jsonb_build_object(
      'driver_id', d.driver_id, 'name', d.nm, 'orders', d.orders,
      'km', round(d.km, 2), 'fail_km', round(coalesce(f.fail_km,0), 2),
      'rated', d.ratedn, 'ممتاز', d.good, 'جيد', d.ok, 'متأخر', d.bad))
      from dstat d left join fkm f on f.driver_id = d.driver_id), '[]'::jsonb),
  'branch_delivered', coalesce((select jsonb_object_agg(branch_id::text, n) from bdone), '{}'::jsonb),
  'orders_tab', jsonb_build_object(
      'cancelled', (select cancelled from k),
      'late', (select late_total from sla_cause),
      'fails_total', (select count(*)::int from pflog),
      'top_cancel', coalesce((select jsonb_agg(jsonb_build_array(nm, n) order by n desc) from topc), '[]'::jsonb),
      'top_late', coalesce((select jsonb_agg(jsonb_build_array(nm, n) order by n desc) from topl), '[]'::jsonb),
      'fail_drivers', coalesce((select jsonb_agg(jsonb_build_array(nm, n) order by n desc) from faild), '[]'::jsonb))
);
$fn$;

-- ═══ ② قوايم الطلبات بتقسيم صفحات على السيرفر ═══
-- p_kind: cancelled | late | perf | all
-- الإجمالي بيتحسب على كل البيانات المفلترة مش على الصفحة (قاعدة الشاشات).
CREATE OR REPLACE FUNCTION public.get_delivery_orders(
  p_from date, p_to date, p_branch uuid DEFAULT NULL,
  p_kind text DEFAULT 'all', p_region text DEFAULT NULL, p_region_branch text DEFAULT NULL,
  p_customer text DEFAULT NULL, p_sort text DEFAULT NULL,
  p_limit int DEFAULT 50, p_offset int DEFAULT 0
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
with rng as (
  select (p_from::timestamp at time zone 'Africa/Cairo') t0,
         ((p_to + 1)::timestamp at time zone 'Africa/Cairo') t1
),
base as (
  select x.*,
         greatest(0, round(coalesce(x.sla_actual_minutes,0) - coalesce(x.sla_minutes,0)))::int late_min
    from orders x, rng
   where x.created_at >= rng.t0 and x.created_at < rng.t1
     and (p_branch is null or x.branch_id = p_branch)
     and (p_kind <> 'cancelled' or x.status = 'cancelled')
     and (p_kind <> 'late'      or x.sla_rating = 'متأخر')
     and (p_kind <> 'perf'      or (x.perf_rating is not null and x.expected_minutes is not null and x.actual_minutes is not null))
     and (p_region is null   or coalesce(nullif(x.cust_region,''),'—') = p_region)
     and (p_region_branch is null or coalesce(x.branch_id::text,'') = p_region_branch)
     and (p_customer is null or coalesce(nullif(x.customer_name,''),'—') = p_customer)
),
page as (
  select * from base
   order by
     case when p_sort = 'late_desc' then late_min end desc nulls last,
     case when p_sort = 'perf_desc' then coalesce(actual_minutes,0) / nullif(expected_minutes,0) end desc nulls last,
     created_at desc
   limit greatest(1, least(coalesce(p_limit,50), 1000)) offset greatest(0, coalesce(p_offset,0))
)
select jsonb_build_object(
  'total', (select count(*)::int from base),
  'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'bill_no', bill_no, 'customer_name', customer_name, 'cust_region', cust_region,
      'branch_id', branch_id, 'total_bill_net', total_bill_net, 'status', status,
      'bill_type', bill_type, 'deliveryman', deliveryman, 'created_at', created_at,
      'perf_rating', perf_rating, 'expected_minutes', expected_minutes, 'actual_minutes', actual_minutes,
      'sla_rating', sla_rating, 'sla_minutes', sla_minutes, 'sla_actual_minutes', sla_actual_minutes,
      'late_min', late_min)) from page), '[]'::jsonb)
);
$fn$;

-- ═══ ③ توقيتات طلب واحد (تشريح التأخير) ═══
-- بنستعمل دالة محروسة بدل قراءة مباشرة من الجدول عشان الشاشة
-- ماتعتمدش على صلاحية SELECT على orders.
CREATE OR REPLACE FUNCTION public.get_order_timeline(p_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  select to_jsonb(t) from (
    select o.id, o.bill_no, o.customer_name, o.cust_region, o.branch_id, o.deliveryman,
           o.created_at, o.last_activated_at, o.assigned_at, o.picked_at, o.delivered_at,
           o.sla_rating, o.sla_minutes, o.sla_actual_minutes,
           o.perf_rating, o.expected_minutes, o.actual_minutes
      from orders o where o.id = p_id
  ) t;
$fn$;

COMMIT;
