-- ═══════════════════════════════════════════════════════════════════
-- get_stock_limits: الفروع من جدول branches
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**) · بيعتمد على branch_code_of() من migrate_39
--
-- نفس عيب get_shortages: الخريطة مكتوبة بالحرف في حساب الرصيد، والفلتر
-- مقارنة نصية (sl.branch = p_branch). فأي اسم بديل أو كود = صفر صفوف.
--
-- وفرق إضافي: الفلتر هنا كان بيقبل 'عام'/'Admin' بس — و'' و null
-- بيرجّعوا **صفر صفوف**، بينما باقي دوال الفروع بتعتبرهم «الكل».
-- وحّدناه. مفيش نداء بيبعت '' أو null دلوقتي: الشاشة بتبعت 'عام'
-- و api.js حاطط `branch || 'عام'`. فالتغيير ده مايأثرش على حاجة شغالة،
-- بس بيشيل فخ للي يعدّل بعدينا.
--
-- ⚠️ dynamic SQL مش view — المزامنة بتعمل rename ثم drop.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.get_stock_limits(p_branch text default null)
returns table(
  id bigint, item_code text, item_name text, item_type text,
  branch text, min_stock numeric, current_stock numeric
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
    with st as (
      select u.br_code, u.code,
             sum(case when u.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$'
                      then u.sto_qty_big::numeric else 0 end) as q
        from (%s) u
       group by u.br_code, u.code
    )
    select sl.id, sl.item_code, sl.item_name, sl.item_type, sl.branch, sl.min_stock,
           coalesce(st.q, 0)::numeric as current_stock
      from public.stock_limit sl
      left join st on st.code = btrim(sl.item_code)
                  and st.br_code = public.branch_code_of(sl.branch)
     where $1 or public.branch_code_of(sl.branch) = $2
     order by (sl.min_stock is null), sl.item_name
  $q$, v_union)
  using v_all, v_code;
end $fn$;

revoke all on function public.get_stock_limits(text) from public, anon;
grant execute on function public.get_stock_limits(text) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- المقارنة قبل/بعد (السحابة 2026-09-24) — صفوف · مجموع الرصيد:
--   عام / Admin      41 · 310.50  →  نفسها
--   المعمورة          9 · 136     →  نفسها
--   سان ستيفانو       8 · 84      →  نفسها
--   سيدى بشر         24 · 90.50   →  نفسها
--   «الصيدلية»        0           →  9 · 136
--   mamora            0           →  9 · 136
--   '' / null         0           →  41 · 310.50   (توحيد مقصود)
-- ═══════════════════════════════════════════════════════════════════
