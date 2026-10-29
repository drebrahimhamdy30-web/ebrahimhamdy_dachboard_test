/* ════════════════════════════════════════════════════════════════
   تبويب «كبار العملاء (VIP)» في شاشة العملاء  (2026-10-29)
   ----------------------------------------------------------------
   طلب المالك: أعلى ٥٠ أو ١٠٠ عميل (حسب الاختيار)، مرتّبين **بالقيمة**
   أو **بعدد الفواتير**. كل فرع يشوف عملاءه، والأدمن يشوف كل الفروع.
   متاح للأدمن ومديري الفروع، والتحكم من شاشة الصلاحيات.

   طريقة الحساب **نفس طريقة تصنيف العميل** الموجودة
   (`refresh_customer_ratings`) عشان مايبقاش عندنا رقمين مختلفين
   لنفس العميل:
     • القيمة  = مجموع `line_total` (سطور الفواتير)
     • الفواتير = `count(distinct bill_no)`
     • استبعاد فواتير التعاقد و السطور ≤ صفر
     • اليوم بتوقيت القاهرة

   الفرع: `sales_items.store_name` اسم مخزن مش اسم فرع («الصيدلية»،
   «ابراهيم حمدي 2»…)، فالربط عبر `branches.aliases` — نفس الخريطة
   اللي باقي الشاشات بتستعملها، مش قايمة مكتوبة بالإيد.

   ⚠️ الحارس على السيرفر: `customers_scope_branch()` بتقرا
   `page_permissions.all_branches` لصفحة `customers`. الأدمن → كل
   الفروع، وغيره → فرعه بس، و**بارامتر الفرع من الشاشة بيتجاهل**
   لغير المصرّح — فالقايمة مش بتتفتح بتغيير الفلتر.

   ملاحظة بيانات: مبيعات العملاء المتاحة من **٢٧ يوليو ٢٠٢٦** (أول
   مزامنة)، فالمدى الافتراضي هو المتاح فعلًا مش «من البداية».

   يتطبّق على: السحابة (اتعمل 2026-10-29) **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── نطاق الفرع لشاشة العملاء (ساكت، بيرجّع اسم الفرع) ──────── */
create or replace function public.customers_scope_branch()
returns text language plpgsql stable security definer set search_path = public as $fn$
declare v_role text := public.jwt_app_role(); v_all boolean; v_br text;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
  then return null; end if;
  if v_role is null then return '__none__'; end if;
  if v_role = 'admin'  then return null; end if;

  select pp.all_branches into v_all
    from page_permissions pp where pp.role = v_role and pp.page_key = 'customers';
  if v_all is null then
    select r.all_branches into v_all from role_branch_scope r where r.role = v_role;
  end if;
  if coalesce(v_all, false) then return null; end if;

  v_br := public.jwt_branch();
  return coalesce((select b.name from branches b
                    where b.name = v_br or v_br = any(coalesce(b.aliases,'{}'::text[])) limit 1),
                  '__none__');
end $fn$;

revoke all on function public.customers_scope_branch() from public, anon;
grant execute on function public.customers_scope_branch() to authenticated;

/* ── كبار العملاء ──────────────────────────────────────────── */
create or replace function public.get_vip_customers(
  p_branch text default null,
  p_from   date default null,
  p_to     date default null,
  p_by     text default 'value',       -- value | bills
  p_limit  int  default 50
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_scope text; v_br text; v_from date; v_to date; v_lim int; v_out jsonb;
begin
  v_scope := public.customers_scope_branch();
  if v_scope = '__none__' then
    raise exception 'غير مصرّح: حسابك غير مربوط بفرع محدّد' using errcode = '42501';
  end if;
  v_br  := coalesce(v_scope, nullif(btrim(coalesce(p_branch,'')),''));
  v_lim := greatest(5, least(coalesce(p_limit, 50), 500));
  select coalesce(p_from, min((bill_date at time zone 'Africa/Cairo')::date)),
         coalesce(p_to,   max((bill_date at time zone 'Africa/Cairo')::date))
    into v_from, v_to from sales_items;

  with s as (
    select si.cust_code,
           b.name  as branch,
           max(si.cust_name)                      as cust_name,
           count(distinct si.bill_no)             as bills,
           sum(si.line_total)                     as net,
           max((si.bill_date at time zone 'Africa/Cairo')::date) as last_buy,
           count(distinct (si.bill_date at time zone 'Africa/Cairo')::date) as buy_days
      from sales_items si
      join branches b on (b.name = si.store_name or si.store_name = any(coalesce(b.aliases,'{}'::text[])))
     where coalesce(si.cust_code,'') <> ''
       and coalesce(si.is_contract,false) = false
       and coalesce(si.line_total,0) > 0
       and (si.bill_date at time zone 'Africa/Cairo')::date between v_from and v_to
       and (v_br is null or b.name = v_br)
     group by si.cust_code, b.name
  ),
  r as (
    select *, row_number() over (
                order by case when p_by = 'bills' then bills else net end desc,
                         case when p_by = 'bills' then net   else bills end desc) rk
      from s
  )
  select jsonb_build_object(
    'from', v_from, 'to', v_to, 'by', coalesce(p_by,'value'),
    'scoped_branch', v_scope,
    'all_customers', (select count(*) from s),
    'all_net',       (select coalesce(sum(net),0) from s),
    'top_net',       (select coalesce(sum(net),0)   from r where rk <= v_lim),
    'top_bills',     (select coalesce(sum(bills),0) from r where rk <= v_lim),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
               'rank', rk, 'cust_code', cust_code, 'cust_name', cust_name, 'branch', branch,
               'bills', bills, 'net', round(net,2),
               'avg_ticket', round(net / nullif(bills,0), 2),
               'buy_days', buy_days, 'last_buy', last_buy) order by rk), '[]'::jsonb)
             from r where rk <= v_lim)
  ) into v_out;
  return v_out;
end $fn$;

revoke all on function public.get_vip_customers(text, date, date, text, int) from public, anon;
grant execute on function public.get_vip_customers(text, date, date, text, int) to authenticated;

/* ── الصلاحيات: الأدمن ومدير الفرع بس ──────────────────────── */
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order)
values ('customers','vip','كبار العملاء (VIP)','.tab-btn[data-tab="vip"]', 5)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

/* الأدوار من القاعدة مش مكتوبة بالإيد — أي دور جديد مابينساش */
insert into public.tab_permissions (page_key, tab_key, role, allowed)
select 'customers','vip', r.role, (r.role = 'manager')
  from (select distinct role from page_permissions where role <> 'admin') r
on conflict (role, page_key, tab_key) do update set allowed = excluded.allowed;
