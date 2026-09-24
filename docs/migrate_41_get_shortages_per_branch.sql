-- ═══════════════════════════════════════════════════════════════════
-- get_shortages: الفروع من جدول branches + تجميعة بدل استعلام مترابط
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**: السحابة والسيرفر الذاتي)
-- بيعتمد على branch_code_of() من migrate_39.
--
-- العيبين:
--   ١) الخريطة كانت مكتوبة بالحرف **مرتين**:
--      • في حساب الرصيد (union على stock_mamora/san/bishr)
--      • وفي فلتر الفرع (x.req_branch = p_branch)
--      فأي اسم بديل ('الصيدلية') أو كود ('mamora') كان بيرجّع **صفر صفوف** —
--      مش رصيد صفر بس، الشاشة كلها تطلع فاضية.
--
--   ٢) حساب الرصيد كان استعلام فرعي **مترابط**: بحث في المخزون لكل صف
--      شحّ على حدة (1703 مرة). دلوقتي تجميعة واحدة + left join.
--
-- ⚠️ dynamic SQL مش view: المزامنة بتعمل rename ثم drop، وأي view بيمنع
--    الـdrop ويوقف المزامنة في كل الفروع (حصل 2026-09-24).
--
-- ملاحظة على req_branch: بتيجي من branch_users بالـusername أو الموبايل،
-- وبترجع لـtask."user" ثم task.branch. وtask."user" ممكن يكون موبايل مش
-- فرع (راجع task-user-branch-mapping). فحصنا 1703 صف — كلهم بيرجعوا
-- لفروع معروفة، فمفيش عطل نشط. والنسخة الجديدة بتحوّلهم لكود الفرع مرة
-- واحدة لكل صف بدل مقارنة نصية.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.get_shortages(p_branch text default null)
returns table(
  id bigint, item_name text, item_code text, "user" text, branch text,
  cust_name text, cust_code text, cust_state text,
  "createdAt" timestamp with time zone, stq numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_union text;
  v_code  text := public.branch_code_of(p_branch);
  v_all   boolean := (p_branch is null
                      or btrim(coalesce(p_branch,'')) in ('عام','Admin','كل الفروع',''));
begin
  -- جداول الفروع الفعّالة اللي جدولها موجود فعلاً
  select string_agg(
           format('select %L::text as br_code, btrim(itm_code) as code, sto_qty_big from public.%I',
                  b.code, 'stock_' || b.code),
           ' union all ')
    into v_union
    from branches b
   where b.is_active
     and to_regclass('public.' || quote_ident('stock_' || b.code)) is not null;

  if v_union is null then
    return;
  end if;

  return query execute format($q$
    with x as (
      select t.id, t.item_name, t.item_code, t."user", t.branch,
             t.cust_name, t.cust_code, t.cust_state, t.created_at,
             public.branch_code_of(
               coalesce((select bu.branch from branch_users bu
                          where bu.username = t."user" or bu.mobile = t."user" limit 1),
                        t."user", t.branch)
             ) as req_code
        from public.task t
       where t.type in ('شراء','تحويل')
         and t.cust_state = 'غير متوفر يحتاج متابعة'
    ),
    st as (
      select u.br_code, u.code,
             sum(case when u.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$'
                      then u.sto_qty_big::numeric else 0 end) as q
        from (%s) u
       group by u.br_code, u.code
    )
    select x.id, x.item_name, x.item_code, x."user", x.branch,
           x.cust_name, x.cust_code, x.cust_state, x.created_at,
           coalesce(st.q, 0)::numeric
      from x
      left join st on st.code = btrim(x.item_code) and st.br_code = x.req_code
     where $1 or x.req_code = $2
     order by x.created_at desc
  $q$, v_union)
  using v_all, v_code;
end $fn$;

revoke all on function public.get_shortages(text) from public, anon;
grant execute on function public.get_shortages(text) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- المقارنة قبل/بعد (السحابة 2026-09-24) — صفوف · مجموع الرصيد · صفوف برصيد:
--   المعمورة      418 · 10.17 · 4   →  نفسها
--   سان ستيفانو   722 · 0     · 0   →  نفسها
--   سيدى بشر      563 · 14    · 8   →  نفسها
--   كل الفروع    1703 · 24.17 · 12  →  نفسها
--   «الصيدلية»      0 · 0     · 0   →  418 · 10.17 · 4
--   mamora          0 · 0     · 0   →  418 · 10.17 · 4
-- ═══════════════════════════════════════════════════════════════════
