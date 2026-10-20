/* ═══════════════════════════════════════════════════════════════════
   تقييم العملاء: الشاشة المبسّطة (رابط ثابت للكل) + نظرة عامة بالرسوم
   ═══════════════════════════════════════════════════════════════════
   قرار المالك (2026-10-21): النظام بقى رابط ثابت لكل فرع في رسالة
   ما بعد الطلب، ومفيش دفعة يومية ولا روابط بتتبعت. فالشاشة بتتبسّط:
     • تبويب «روابط اليوم» بيتشال، وكرون الدفعة بيتوقّف (الدوال فاضلة
       لو رجع للفكرة — `batch_enabled` في الإعدادات هو المفتاح).
     • المؤشر الأساسي بقى **نسبة التقييم** = التقييمات ÷ طلبات التوصيل
       الموصّلة في الفترة (بديل «نسبة الاستجابة» اللي كانت على الإرسال).
     • دالة واحدة `rating_overview` بترجّع كل اللي الشاشة محتاجاه:
       المؤشرات + مقارنة بالفترة السابقة + التقييمات يومًا بيوم + توزيع
       النجوم + الفروع + الترتيب مع اتجاه آخر 4 أسابيع لكل شخص.
   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

begin;

alter table public.rating_settings add column if not exists batch_enabled boolean not null default false;

/* نبضة الكرون: بتتوقّف لما الدفعة مقفولة (التنظيف بس) */
create or replace function public.rating_batch_tick()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_y date := (now() at time zone 'Africa/Cairo')::date - 1;
        v_h int  := extract(hour from (now() at time zone 'Africa/Cairo'))::int;
        s public.rating_settings%rowtype;
begin
  perform public.require_app_role(array['admin','manager']);
  delete from public.rating_bill_lookups where created_at < now() - interval '2 days';
  select * into s from public.rating_settings where id = 1;
  update public.order_rating_links set status = 'expired'
   where status = 'sent' and expires_at < now();
  if not s.batch_enabled then
    return jsonb_build_object('skipped', 'batch_disabled');
  end if;
  if v_h < s.batch_hour then
    return jsonb_build_object('skipped', 'before_hour', 'hour', v_h);
  end if;
  if exists (select 1 from public.order_rating_links where batch_date = v_y) then
    update public.order_rating_links set status = 'dropped'
     where status = 'pending' and created_at < now() - make_interval(days => s.unsent_drop_days);
    return jsonb_build_object('skipped', 'already', 'date', v_y);
  end if;
  return public.rating_generate_batch(v_y);
end $fn$;

/* الكرون يفضل شغّال كل ساعة للتنظيف بس (رخيص) */

/* ── النظرة العامة ─────────────────────────────────────────────── */
create or replace function public.rating_overview(p_from date, p_to date, p_branch_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare
  v_b uuid; v_len int; v_pfrom date; v_pto date;
  v_k jsonb; v_prev jsonb; v_daily jsonb; v_dist jsonb; v_br jsonb; v_e jsonb; v_d jsonb; v_orders int;
begin
  if public.jwt_app_role() is null
     and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  v_b := public.rating_scope_branch(p_branch_id);
  v_len  := greatest(1, p_to - p_from + 1);
  v_pto  := p_from - 1;
  v_pfrom := v_pto - v_len + 1;

  /* طلبات التوصيل الموصّلة في الفترة — مقام نسبة التقييم */
  select count(*) into v_orders
    from public.orders o
   where o.status in ('delivered','completed') and o.delivered_at is not null
     and (o.delivered_at at time zone 'Africa/Cairo')::date between p_from and p_to
     and (v_b is null or o.branch_id = v_b);

  select jsonb_build_object(
           'rated', count(*),
           'delivered_orders', v_orders,
           'rate_pct', case when v_orders > 0 then round(100.0 * count(*) / v_orders, 1) else null end,
           'avg_all',      round(avg((l.employee_stars + l.driver_stars + coalesce(l.speed_stars, l.driver_stars)) / 3.0)::numeric, 2),
           'avg_employee', round(avg(l.employee_stars)::numeric, 2),
           'avg_driver',   round(avg(l.driver_stars)::numeric, 2),
           'avg_speed',    round(avg(l.speed_stars)::numeric, 2))
    into v_k
    from public.order_rating_links l
   where l.rated_at is not null
     and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
     and (v_b is null or l.branch_id = v_b);

  select jsonb_build_object(
           'rated', count(*),
           'avg_all',      round(avg((l.employee_stars + l.driver_stars + coalesce(l.speed_stars, l.driver_stars)) / 3.0)::numeric, 2),
           'avg_employee', round(avg(l.employee_stars)::numeric, 2),
           'avg_driver',   round(avg(l.driver_stars)::numeric, 2),
           'avg_speed',    round(avg(l.speed_stars)::numeric, 2))
    into v_prev
    from public.order_rating_links l
   where l.rated_at is not null
     and (l.rated_at at time zone 'Africa/Cairo')::date between v_pfrom and v_pto
     and (v_b is null or l.branch_id = v_b);

  select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n, 'avg', a) order by d), '[]'::jsonb) into v_daily
    from (select (l.rated_at at time zone 'Africa/Cairo')::date d, count(*) n,
                 round(avg((l.employee_stars + l.driver_stars + coalesce(l.speed_stars, l.driver_stars)) / 3.0)::numeric, 2) a
            from public.order_rating_links l
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by 1) x;

  /* توزيع النجوم على الأسئلة الثلاثة معًا */
  select jsonb_build_object(
           '5', count(*) filter (where v = 5), '4', count(*) filter (where v = 4), '3', count(*) filter (where v = 3),
           '2', count(*) filter (where v = 2), '1', count(*) filter (where v = 1))
    into v_dist
    from (select unnest(array[l.employee_stars, l.driver_stars, l.speed_stars]) v
            from public.order_rating_links l
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)) s
   where v is not null;

  select coalesce(jsonb_agg(x order by x.avg desc nulls last), '[]'::jsonb) into v_br
    from (select b.name, round(avg((l.employee_stars + l.driver_stars + coalesce(l.speed_stars, l.driver_stars)) / 3.0)::numeric, 2) avg, count(*) n
            from public.order_rating_links l join public.branches b on b.id = l.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by b.name) x;

  /* الاتجاه: متوسط كل أسبوع من آخر 4 أسابيع تنتهي بـp_to (null = مفيش تقييمات) */
  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_e
    from (select l.employee_name as name, b.name as branch,
                 round(avg(l.employee_stars)::numeric, 2) as avg, count(*) as n,
                 (select jsonb_agg(w.a order by w.wk)
                    from (select ((p_to - (t.rated_at at time zone 'Africa/Cairo')::date) / 7) wk,
                                 round(avg(t.employee_stars)::numeric, 2) a
                            from public.order_rating_links t
                           where t.rated_at is not null and t.employee_name = l.employee_name
                             and t.branch_id is not distinct from l.branch_id
                             and (t.rated_at at time zone 'Africa/Cairo')::date between p_to - 27 and p_to
                           group by 1) w) as trend
            from public.order_rating_links l
            left join public.branches b on b.id = l.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.employee_name, l.branch_id, b.name) x;

  select coalesce(jsonb_agg(x order by x.avg desc, x.n desc), '[]'::jsonb) into v_d
    from (select l.driver_id, coalesce(d.full_name, l.driver_name) as name, b.name as branch,
                 round(avg(l.driver_stars)::numeric, 2) as avg, count(*) as n,
                 round(avg(l.speed_stars)::numeric, 2) as avg_speed,
                 (select jsonb_agg(w.a order by w.wk)
                    from (select ((p_to - (t.rated_at at time zone 'Africa/Cairo')::date) / 7) wk,
                                 round(avg(t.driver_stars)::numeric, 2) a
                            from public.order_rating_links t
                           where t.rated_at is not null and t.driver_id = l.driver_id
                             and (t.rated_at at time zone 'Africa/Cairo')::date between p_to - 27 and p_to
                           group by 1) w) as trend
            from public.order_rating_links l
            left join public.drivers d on d.id = l.driver_id
            left join public.branches b on b.id = d.branch_id
           where l.rated_at is not null
             and (l.rated_at at time zone 'Africa/Cairo')::date between p_from and p_to
             and (v_b is null or l.branch_id = v_b)
           group by l.driver_id, d.full_name, l.driver_name, b.name) x;

  return jsonb_build_object('kpis', v_k, 'prev', v_prev, 'daily', v_daily, 'dist', v_dist,
                            'branches', v_br, 'employees', v_e, 'drivers', v_d,
                            'period', jsonb_build_object('from', p_from, 'to', p_to, 'prev_from', v_pfrom, 'prev_to', v_pto),
                            'scoped_branch', v_b);
end $fn$;

revoke all on function public.rating_overview(date, date, uuid) from public, anon;
grant execute on function public.rating_overview(date, date, uuid) to authenticated, service_role;

/* تبويب الروابط يتشال من الشاشة (صلاحياته بتتمسح معاه) */
delete from public.app_page_tabs where page_key = 'ratings' and tab_key = 'links';

notify pgrst, 'reload schema';

commit;
