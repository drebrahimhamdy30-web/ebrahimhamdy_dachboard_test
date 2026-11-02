-- ═══════════════════════════════════════════════════════════════════
--  مديونيات العملاء — «له ادويه بقيمة» (كود 101 عندنا)
-- ═══════════════════════════════════════════════════════════════════
--  العميل بيدفع والدوا مش موجود، فبيتكتب له سطر بالكود ده. ولما ياخد
--  الدوا بتترد القيمة على **نفس سطر البيع** في eplus (itm_back /
--  itm_back_price) — مش بمستند مرتجع منفصل. اتأكد 2026-11-02 على ٤
--  فواتير: المسوّاة itm_back=1 بكامل القيمة، والمفتوحة صفر.
--
--  ليه جدول مستقل مش توسيع sales_items:
--  sales_items بتبدأ 2026-07-27 (أول مزامنة) وبتتعامل كمصدر كامل
--  للفترة دي. لو حقنّا فيها سطور 101 من 2023 بس، أي تقرير بيقرا
--  sales_items هيلاقي فترة فيها سطر واحد من الفاتورة — تاريخ ناقص
--  بيبان كامل. الجدول ده حبّته «سطر مديونية» مش «سطر فاتورة».
--
--  ⚠️ كود الصنف في eplus مش 101: في قاعدة المعمورة itm_id=51686،
--     و itm_id=101 مالوش ولا سطر. كل فرع قاعدة منفصلة فالكود ممكن
--     يختلف — سكربت التجميع بيحدّده بالفحص لكل فرع مش بالافتراض.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.customer_credits (
  branch         text not null,                 -- mamora / san / bishr / seyouf
  bill_no        text not null,                 -- sth_id
  line_no        integer not null,              -- std_id
  bill_date      timestamptz not null,
  store_name     text,
  cust_code      text,
  cust_name      text,
  cust_mobile    text,
  employee_name  text,
  value          numeric(14,2) not null,
  returned_value numeric(14,2) not null default 0,
  remaining      numeric(14,2) generated always as (value - returned_value) stored,
  synced_at      timestamptz not null default now(),
  primary key (branch, bill_no, line_no)
);
comment on table public.customer_credits is
  'مديونيات العملاء: سطور «له ادويه بقيمة» من eplus وقيمة اللي اتسلّمه العميل منها.';

create index if not exists customer_credits_branch_date_idx on public.customer_credits (branch, bill_date desc);
create index if not exists customer_credits_cust_idx        on public.customer_credits (cust_code);
create index if not exists customer_credits_open_idx        on public.customer_credits (branch, bill_date desc)
  where (value - returned_value) > 0.5;

alter table public.customer_credits enable row level security;
revoke all on public.customer_credits from public, anon;
grant select on public.customer_credits to authenticated;
grant all    on public.customer_credits to service_role;

drop policy if exists customer_credits_read on public.customer_credits;
create policy customer_credits_read on public.customer_credits
  for select to authenticated using (true);   -- القصر على الفرع جوّه الدالة

-- ── الحارس: الفرع من التوكن مش من الطلب ────────────────────────────
create or replace function public.credits_scope_branch(p_branch text)
returns text
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select case when public.jwt_all_branches()
              or coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
         then nullif(btrim(coalesce(p_branch,'')), '')
         else public.branch_code_of(public.jwt_branch()) end;
$function$;
revoke all on function public.credits_scope_branch(text) from public;
grant execute on function public.credits_scope_branch(text) to authenticated, service_role;

-- ── الشاشة: إجماليات وتقادم على كل البيانات المفلترة + صفحة عرض ───
create or replace function public.get_customer_credits(
  p_branch text default null,
  p_status text default 'open',      -- open | settled | all
  p_search text default null,        -- كود/اسم/موبايل/رقم فاتورة
  p_from   date default null,
  p_to     date default null,
  p_limit  integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_role text := public.jwt_app_role();
  v_b    text;
  v_q    text := nullif(btrim(coalesce(p_search,'')), '');
  v_lim  int  := greatest(1, least(200, coalesce(p_limit, 50)));
  v_off  int  := greatest(0, coalesce(p_offset, 0));
  v_out  jsonb;
begin
  if not (coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
          or v_role in ('admin','manager','accountant')) then
    raise exception 'غير مصرّح' using errcode = '42501';
  end if;
  v_b := public.credits_scope_branch(p_branch);

  with f as (
    select c.*,
           (current_date - (c.bill_date at time zone 'Africa/Cairo')::date) as age_days
      from public.customer_credits c
     where (v_b is null or c.branch = v_b)
       and (p_from is null or (c.bill_date at time zone 'Africa/Cairo')::date >= p_from)
       and (p_to   is null or (c.bill_date at time zone 'Africa/Cairo')::date <= p_to)
       and (p_status = 'all'
            or (p_status = 'open'    and c.remaining >  0.5)
            or (p_status = 'settled' and c.remaining <= 0.5))
       and (v_q is null
            or c.bill_no = v_q
            or c.cust_code = v_q
            or c.cust_name   ilike '%'||v_q||'%'
            or c.cust_mobile like '%'||v_q||'%')
  )
  select jsonb_build_object(
    'total',      (select count(*) from f),
    'sum_value',  (select coalesce(round(sum(value),2),0)     from f),
    'sum_paid',   (select coalesce(round(sum(returned_value),2),0) from f),
    'sum_open',   (select coalesce(round(sum(remaining),2),0) from f),
    'customers',  (select count(distinct coalesce(nullif(cust_code,''),'—')) from f),
    'aging',      (select coalesce(jsonb_agg(x order by x->>'k'), '[]'::jsonb) from (
                     select jsonb_build_object('k', k, 'bills', count(*), 'value', round(sum(remaining),2)) x
                       from (select case when age_days <= 30 then '1'
                                         when age_days <= 60 then '2'
                                         when age_days <= 90 then '3'
                                         when age_days <= 365 then '4'
                                         else '5' end k, remaining
                               from f where remaining > 0.5) t
                      group by k) y),
    'by_branch',  (select coalesce(jsonb_agg(jsonb_build_object(
                             'branch', branch, 'bills', n, 'value', v) order by v desc), '[]'::jsonb)
                     from (select branch, count(*) n, round(sum(remaining),2) v
                             from f where remaining > 0.5 group by branch) b),
    'rows',       (select coalesce(jsonb_agg(jsonb_build_object(
                             'branch', branch, 'bill_no', bill_no, 'line_no', line_no,
                             'bill_date', bill_date, 'store_name', store_name,
                             'cust_code', cust_code, 'cust_name', cust_name, 'cust_mobile', cust_mobile,
                             'employee_name', employee_name,
                             'value', value, 'returned_value', returned_value,
                             'remaining', remaining, 'age_days', age_days)
                           order by bill_date desc, bill_no desc), '[]'::jsonb)
                     from (select * from f order by bill_date desc, bill_no desc
                            limit v_lim offset v_off) p)
  ) into v_out;

  return v_out;
end $function$;

revoke all on function public.get_customer_credits(text,text,text,date,date,integer,integer) from public;
grant execute on function public.get_customer_credits(text,text,text,date,date,integer,integer) to authenticated, service_role;

-- ── تسجيل الشاشة ──────────────────────────────────────────────────
insert into public.app_pages (key, file, title, section, sort_order, is_active)
values ('customer_credits', 'customer_credits.html', 'مديونيات العملاء', 'التعاقدات والتحصيل', 528, true)
on conflict (key) do update set file = excluded.file, title = excluded.title,
                                section = excluded.section, is_active = true;

-- ⚠️ صف بلا can_view=true = شاشة مخفية بالصمت
insert into public.page_permissions (role, page, can_view, can_edit, all_branches)
values ('admin',      'customer_credits.html', true,  false, true),
       ('manager',    'customer_credits.html', true,  false, true),
       ('accountant', 'customer_credits.html', true,  false, false)
on conflict (role, page) do update set can_view = true;

notify pgrst, 'reload schema';
