/* ============================================================
   تصنيف العملاء — RFM + إيقاع العميل + اتجاه الشراء
   ------------------------------------------------------------
   بالمبيعات وحدها. الربحية اتشالت بقرار المالك: مفيش عمود تكلفة،
   وخصومات الموردين (اللي كانت البديل) فيها قيم تالفة وأصناف كتير
   خصمها مش ممثّل (ورقيات/ثلاجة)، فالرقم كان بيوهم بدقة مش موجودة.

   التلات محاور:

   1) RFM — المعيار القياسي: آخر شراء × التكرار × القيمة، كل محور
      درجة 1..5 بحدود محسوبة من توزيع العملاء نفسه (مش أرقام محفورة)،
      والناتج تصنيف من الـ11 تصنيف المتعارف عليها.
      الحدود بتتحسب بـpercentile وبمقارنة >= عشان **المتساويين ياخدوا
      نفس الدرجة** (ntile كان بيحطّ عميلين عندهم فاتورة واحدة في
      درجتين مختلفتين).

   2) إيقاع العميل (avg_gap) — ليه ده مهم:
      «آخر شراء ≤ 30 يوم = نشط» بتضيّع عملاء. ربع العملاء بيشتروا كل
      5 أيام والنص كل 8. العميل اللي إيقاعه 5 أيام وغايب 15 يوم اتوقف
      فعليًا وهو لسه «نشط» بالقاعدة الثابتة. القياس بإيقاعه الخاص كشف
      867 عميل متأخرين (1.56 مليون ج) منهم 515 شاريين خلال آخر 30 يوم
      — يعني أي نظام بالـ30 يوم مش شايفهم.

   3) الاتجاه — آخر 30 يوم مقابل الـ30 اللي قبلها: بيكشف التدهور قبل
      الانسحاب (1,525 بيزيدوا / 1,260 بينقصوا للنص / 384 وقفوا).

   عملاء التعاقد مستبعدون من التصنيف بقرار الإدارة.
   CLV التنبؤي (BG/NBD) مؤجّل: محتاج سنة بيانات، والمتاح 72 يوم.
   ============================================================ */

-- مخلّفات نسخة الربحية (لو الترحيل اتطبّق قبل القرار) ------------------
drop function if exists public.get_customer_rating(text);
drop table    if exists public.customer_rating_flat;
drop table    if exists public.customer_profit_rates;

-- 1) الجدول المسطّح ---------------------------------------------------
create table public.customer_rating_flat (
  cust_code      text primary key,
  cust_name      text,
  bills          integer not null default 0,
  buy_days       integer not null default 0,   -- أيام مختلفة شرى فيها
  contract_bills integer not null default 0,
  sales          numeric not null default 0,
  returns_val    numeric not null default 0,
  net            numeric not null default 0,
  avg_ticket     numeric,
  ret_pct        numeric,
  first_buy      date,
  last_buy       date,
  days_since     integer,
  active_weeks   integer not null default 0,
  avg_gap        numeric,                      -- إيقاعه: متوسط الأيام بين الشراء
  gap_cv         numeric,                      -- تقلّب الإيقاع (0 = منتظم تمامًا)
  late_x         numeric,                      -- غيابه ÷ إيقاعه
  expected_next  date,                         -- موعده المتوقّع
  v30            numeric not null default 0,
  v_prev30       numeric not null default 0,
  trend          text    not null default 'na',-- up | flat | down | stopped | start | na
  r_score        smallint,
  f_score        smallint,
  m_score        smallint,
  rfm            text,                          -- مثال '534'
  value_rank     integer,
  value_pr       numeric,
  seg            text    not null default 'none',
  flags          text[]  not null default '{}',
  computed_at    timestamptz not null default now()
);
create index idx_crf_seg   on public.customer_rating_flat(seg);
create index idx_crf_net   on public.customer_rating_flat(net desc);
create index idx_crf_late  on public.customer_rating_flat(late_x desc);

-- 2) الحساب -----------------------------------------------------------
create or replace function public.refresh_customer_ratings()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_asof date;
  v_n    integer;
begin
  select max((bill_date at time zone 'Africa/Cairo')::date) into v_asof from sales_items;
  if v_asof is null then return 0; end if;

  /* لو الدالة اتنادت مرتين في نفس المعاملة */
  drop table if exists _c;
  create temp table _c on commit drop as
  with b as (
    /* يوم شراء واحد = صف واحد: الفواتير المتعددة في نفس اليوم مش
       بتزوّد «إيقاعه» ولا بتعمل فاصل صفر يبوّظ المتوسط */
    select cust_code,
           (bill_date at time zone 'Africa/Cairo')::date as d,
           max(cust_name)             as cust_name,
           sum(line_total)            as v,
           count(distinct bill_no)    as nb
      from sales_items
     where coalesce(cust_code,'') <> ''
       and coalesce(is_contract, false) = false
       and coalesce(line_total, 0) > 0
     group by 1, 2
  ),
  g as (
    select b.*, (b.d - lag(b.d) over (partition by b.cust_code order by b.d))::numeric as gp
      from b
  ),
  s as (
    select cust_code,
           max(cust_name)                                        as cust_name,
           sum(nb)::int                                          as bills,
           count(*)::int                                         as buy_days,
           sum(v)                                                as sales,
           min(d)                                                as first_buy,
           max(d)                                                as last_buy,
           avg(gp)                                               as avg_gap,
           stddev_pop(gp)                                        as sd_gap,
           coalesce(sum(v) filter (where d >  v_asof - 30), 0)    as v30,
           coalesce(sum(v) filter (where d <= v_asof - 30
                                     and d >  v_asof - 60), 0)    as v_prev30,
           count(distinct date_trunc('week', d))::int             as active_weeks
      from g group by cust_code
  ),
  ct as (
    select cust_code, count(distinct bill_no)::int cb
      from sales_items
     where coalesce(cust_code,'') <> '' and coalesce(is_contract,false) = true
     group by cust_code
  ),
  rt as (
    select cust_code, sum(coalesce(return_value,0)) rv
      from returns_log where coalesce(cust_code,'') <> '' group by cust_code
  )
  select coalesce(s.cust_code, ct.cust_code)                      as cust_code,
         s.cust_name,
         coalesce(s.bills, 0)                                     as bills,
         coalesce(s.buy_days, 0)                                  as buy_days,
         coalesce(ct.cb, 0)                                       as contract_bills,
         round(coalesce(s.sales, 0))                              as sales,
         round(coalesce(rt.rv, 0))                                as returns_val,
         round(greatest(coalesce(s.sales,0) - coalesce(rt.rv,0), 0)) as net,
         case when coalesce(s.bills,0) > 0
              then round(s.sales / s.bills) end                   as avg_ticket,
         case when coalesce(s.sales,0) > 0
              then round(100.0 * coalesce(rt.rv,0) / s.sales, 1)
              else 0 end                                          as ret_pct,
         s.first_buy, s.last_buy,
         case when s.last_buy is not null
              then (v_asof - s.last_buy)::int end                 as days_since,
         coalesce(s.active_weeks, 0)                              as active_weeks,
         /* الإيقاع يتحسب بس لو 3 أيام شراء أو أكتر — فاصل واحد مش إيقاع */
         case when coalesce(s.buy_days,0) >= 3
              then round(s.avg_gap, 1) end                        as avg_gap,
         case when coalesce(s.buy_days,0) >= 3 and s.avg_gap > 0
              then round(s.sd_gap / s.avg_gap, 2) end             as gap_cv,
         coalesce(s.v30, 0)                                       as v30,
         coalesce(s.v_prev30, 0)                                  as v_prev30
    from s
    full join ct on ct.cust_code = s.cust_code
    left join rt on rt.cust_code = coalesce(s.cust_code, ct.cust_code);

  truncate table customer_rating_flat;

  insert into customer_rating_flat (
    cust_code, cust_name, bills, buy_days, contract_bills, sales, returns_val, net,
    avg_ticket, ret_pct, first_buy, last_buy, days_since, active_weeks,
    avg_gap, gap_cv, late_x, expected_next, v30, v_prev30, trend,
    r_score, f_score, m_score, rfm, value_rank, value_pr, seg, flags, computed_at)
  with sc as (
    select c.*,
           case when c.avg_gap > 0 then round(c.days_since / c.avg_gap, 2) end as late_x,
           case when c.avg_gap is not null
                then c.last_buy + (round(c.avg_gap))::int end as expected_next,
           case when c.bills = 0                                    then 'na'
                when c.v_prev30 = 0 and c.v30 > 0                   then 'start'
                when c.v_prev30 > 0 and c.v30 = 0                   then 'stopped'
                when c.v_prev30 > 0 and c.v30 <  c.v_prev30 * 0.5   then 'down'
                when c.v_prev30 > 0 and c.v30 >  c.v_prev30 * 1.5   then 'up'
                else 'flat' end as trend
      from _c c
  ),
  v as (
    /* الدرجات 1..5 بـpercent_rank على العملاء المؤهّلين (غير متعاقدين وليهم شراء).
       percent_rank بيدّي **المتساويين نفس القيمة** وبيبدأ من صفر، فالقيمة
       الأدنى بتاخد درجة 1 فعلًا. الحدود بالـpercentile كانت بتفشل هنا:
       32% من العملاء عندهم فاتورة واحدة فحد الـ20% طلع = 1، و«bills >= 1»
       صحيح للكل، فمحدش أخد درجة 1 وتصنيف «عميل جديد» طلع صفر عميل. */
    select sc.cust_code,
           row_number()  over (order by sc.net desc) rnk,
           percent_rank() over (order by sc.net)     pr,
           least(5, floor(percent_rank() over (order by sc.days_since desc) * 5) + 1)::smallint r_score,
           least(5, floor(percent_rank() over (order by sc.bills)           * 5) + 1)::smallint f_score,
           least(5, floor(percent_rank() over (order by sc.net)             * 5) + 1)::smallint m_score
      from sc
     where sc.contract_bills = 0 and sc.bills > 0
  ),
  z as (
    select sc.*, v.rnk, v.pr, v.r_score, v.f_score, v.m_score,
           /* FM = متوسط التكرار والقيمة، زي المصفوفة المتعارف عليها */
           ((v.f_score + v.m_score) / 2.0) as fm
      from sc left join v on v.cust_code = sc.cust_code
  )
  select z.cust_code,
         z.cust_name,
         z.bills, z.buy_days, z.contract_bills, z.sales, z.returns_val, z.net,
         z.avg_ticket, z.ret_pct, z.first_buy, z.last_buy, z.days_since, z.active_weeks,
         z.avg_gap, z.gap_cv, z.late_x, z.expected_next, z.v30, z.v_prev30, z.trend,
         z.r_score, z.f_score, z.m_score,
         case when z.r_score is null then null
              else z.r_score::text || z.f_score::text || z.m_score::text end,
         z.rnk, round(z.pr::numeric, 4),
         case
           when z.contract_bills > 0                              then 'contract'
           when z.bills = 0                                       then 'none'
           /* «جديد» قبل «وفي»: صاحب الفاتورة الواحدة الكبيرة fm بتاعه 3
              فكان بيتسمّى «وفي» وهو عمره ما رجع */
           when z.f_score = 1 and z.r_score >= 4                  then 'new'
           when z.r_score >= 4 and z.fm >= 4                      then 'champion'
           when z.r_score <= 2 and z.fm >= 4.5                    then 'cant_lose'
           when z.r_score <= 2 and z.fm >= 3                      then 'at_risk'
           when z.r_score >= 3 and z.fm >= 3                      then 'loyal'
           when z.r_score >= 4 and z.fm >= 2                      then 'potential'
           /* >= 4 مش = 4: عميل شارى امبارح بإيقاع متقلّب كان بيوقع في else = «منسحب» */
           when z.r_score >= 4                                    then 'promising'
           when z.r_score = 3                                     then 'about_to_sleep'
           when z.r_score <= 2 and z.fm >= 2                      then 'hibernating'
           else 'lost'
         end as seg,
         (array_remove(array[
            /* العلامة اللي الحدود الثابتة مابتشوفهاش: متأخر عن إيقاعه هو */
            case when z.late_x >= 2 then 'late' end,
            case when z.trend = 'down' then 'declining' end,
            case when z.trend = 'stopped' then 'stopped' end,
            case when z.gap_cv is not null and z.gap_cv <= 0.4 then 'regular' end,
            case when z.ret_pct > 30 then 'high_returns' end,
            case when z.contract_bills > 0 and z.bills > 0 then 'mixed_contract' end
          ], null))::text[],
         now()
    from z;

  select count(*) into v_n from customer_rating_flat;
  return v_n;
end
$fn$;

-- 3) قراءة عميل واحد (jsonb — صف واحد، مش متأثر بسقف الألف صف) ---------
create or replace function public.get_customer_rating(p_cust_code text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(
    (select to_jsonb(f) || jsonb_build_object(
              'seg_label', case f.seg
                 when 'contract'       then 'عميل تعاقد — مستبعد من التصنيف'
                 when 'champion'       then 'عميل نجم'
                 when 'loyal'          then 'عميل وفي'
                 when 'cant_lose'      then 'لا يجب خسارته'
                 when 'at_risk'        then 'في خطر'
                 when 'potential'      then 'عميل واعد'
                 when 'new'            then 'عميل جديد'
                 when 'promising'      then 'عميل مبشّر'
                 when 'about_to_sleep' then 'على وشك الانسحاب'
                 when 'hibernating'    then 'عميل خامل'
                 when 'lost'           then 'عميل منسحب'
                 else 'لا مبيعات في الفترة' end,
              'value_top_pct',
                 case when f.value_pr is not null
                      then round((100 - f.value_pr * 100)::numeric, 1) end,
              'rated_customers', (select count(*) from customer_rating_flat
                                   where value_pr is not null),
              'asof', (select max(last_buy) from customer_rating_flat))
       from customer_rating_flat f where f.cust_code = p_cust_code),
    jsonb_build_object('cust_code', p_cust_code, 'seg', 'none',
                       'seg_label', 'لا مبيعات في الفترة'));
$fn$;

revoke all on function public.refresh_customer_ratings()    from public, anon;
revoke all on function public.get_customer_rating(text)     from public, anon;
grant execute on function public.get_customer_rating(text)  to authenticated;
grant execute on function public.refresh_customer_ratings() to service_role;
revoke all on table public.customer_rating_flat from anon;
grant select on table public.customer_rating_flat to authenticated;

/* تحديث مجدول كل ساعة (الدقيقة 50) */
select cron.unschedule('refresh_customer_ratings_hourly')
 where exists (select 1 from cron.job where jobname = 'refresh_customer_ratings_hourly');
select cron.schedule('refresh_customer_ratings_hourly', '50 * * * *',
                     'select public.refresh_customer_ratings();');
select public.refresh_customer_ratings();
