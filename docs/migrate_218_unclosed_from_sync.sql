-- ═══════════════════════════════════════════════════════════════════
--  «طلبات لم تُغلق على B Connect» من سحبة المزامنة بدل نداء B Connect
-- ═══════════════════════════════════════════════════════════════════
--  القياس (2026-11-16): التبويب بينده B Connect (DeliveryBill Pending)
--  ~85 مرة/ساعة، كل نداء ~7ث (فحص ترخيص B-Connect جوّه الـAPI)، والمهلة
--  في الشاشة 20ث فـ~10% بيظهر «تعذّر الاتصال».
--
--  في نفس الوقت `scripts/sync_pending_orders.ps1` بيقرا **كل** فواتير
--  التوصيل المفتوحة (sth_flag='P') من قاعدة eplus مباشرة كل دقيقة (0.14ث)
--  وبيعمل upsert في orders — بس مكانش بيسيب أثر على الطلب إنه ظهر مفتوح،
--  و bill_status بيتكتب 'Pending' مرة وقت الإدراج وبيفضل كده للأبد (435 طلب
--  مكتمل في المعمورة يوم 16/11 كلهم 'Pending').
--
--  الحل: السكربت يختم `bill_seen_at` = وقت بداية السحبة على كل فاتورة
--  مفتوحة. فالفواتير اللي ختمها من آخر سحبة ناجحة = المفتوحة دلوقتي على
--  eplus. والتبويب = منها اللي رحلته اكتملت.
--
--  ⚠️ «حيّ» لفرع = آخر تشغيل ok أحدث من 3 دقايق **و** فعلًا ختم فواتير
--     (أو مالقاش ولا فاتورة مفتوحة). من غير الشرط التاني، فرع السكربت
--     بتاعه لسه قديم (مابيختمش) كان هيبان «حيّ» بقايمة فاضية = كذب.
--     الفرع اللي مش حيّ الشاشة بترجع فيه لـB Connect زي الأول.
--  ⚠️ العتبة = ran_at − مدة التشغيل − 15ث: bill_seen_at = بداية السحبة،
--     و ran_at بيتسجّل في آخرها؛ والسحبة اللي قبلها أقدم بدقيقة فبتطلع برّه.
-- ═══════════════════════════════════════════════════════════════════

alter table public.orders add column if not exists bill_seen_at timestamptz;
comment on column public.orders.bill_seen_at is
  'آخر سحبة لقت فيها sync_pending_orders الفاتورة مفتوحة (sth_flag=P) على eplus';
create index if not exists ix_orders_bill_seen
  on public.orders (branch_id, bill_seen_at) where bill_seen_at is not null;

create or replace function public.get_unclosed_from_sync(
  p_branch        uuid    default null,
  p_stale_seconds integer default 180
)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  with br as (
    select b.id, b.code
      from public.branches b
     where b.is_active and (p_branch is null or b.id = p_branch)
  ), st as (
    select br.id as branch_id, br.code, r.ran_at, r.new_rows, r.item_rows,
           r.ran_at - make_interval(secs => coalesce(r.duration_ms, 0) / 1000.0 + 15) as threshold
      from br
      left join lateral (
        select s.ran_at, s.duration_ms, s.new_rows, s.item_rows
          from public.sync_runs s
         where s.job_id = 'delivery_orders' and s.branch = br.code and s.status = 'ok'
         order by s.ran_at desc
         limit 1) r on true
  ), live as (
    select st.*,
           ( st.ran_at > now() - make_interval(secs => greatest(coalesce(p_stale_seconds, 180), 30))
             and ( coalesce(st.new_rows, 0) + coalesce(st.item_rows, 0) = 0
                   or exists (select 1 from public.orders o
                               where o.branch_id = st.branch_id and o.bill_seen_at >= st.threshold) )
           ) as is_live
      from st
  )
  select jsonb_build_object(
    'branches', coalesce((select jsonb_agg(jsonb_build_object(
                   'branch_id', l.branch_id, 'code', l.code, 'live', coalesce(l.is_live, false),
                   'last_run_at', l.ran_at)) from live l), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select o.id, o.bill_no, o.cust_code, o.customer_name,
               o.total_bill_net as amount,
               'Pending'::text as erp_status,
               coalesce(o.completed_at, o.updated_at, o.created_at) as created_at,
               coalesce(d.full_name, o.deliveryman) as driver_name,
               o.cust_region, o.customer_address, o.status as order_status,
               o.payment_method, o.branch_id,
               (select tox.trip_id from public.trip_orders tox join public.trips t on t.id = tox.trip_id
                 where tox.order_id = o.id order by (t.status = 'completed') desc, t.created_at desc limit 1) as trip_id
          from public.orders o
          join live l on l.branch_id = o.branch_id and l.is_live
          left join public.drivers d on d.id = o.driver_id
         where o.driver_id is not null
           and o.bill_seen_at >= l.threshold
           and ( o.status = 'completed'
             or ( o.status = 'delivered'
                  and exists (select 1 from public.trip_orders tox join public.trips t on t.id = tox.trip_id
                              where tox.order_id = o.id and t.status = 'completed') ) )
      ) x), '[]'::jsonb)
  );
$$;

revoke all on function public.get_unclosed_from_sync(uuid, integer) from public, anon;
grant execute on function public.get_unclosed_from_sync(uuid, integer) to authenticated, service_role;
