-- ═══════════════════════════════════════════════════════════════════
-- حرف الفرع في جدول الفروع + دالتين مخزون يقروا منه
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**: السحابة والسيرفر الذاتي)
--
-- العيب اللي بيتصلح:
--   `stock_flat` فيه أعمدة السيوف بالفعل (f_h, f_q, f_p) و3,832 صنف
--   برصيد وسعر. بس دالتين بيقروا منه لسه ثلاثيين مكتوبين بالإيد:
--     • quick_search_stock  → البحث السريع في delivery/app.html
--     • get_min_stock_alerts → شاشة الحد الأدنى للمخزون
--   فالبيانات موجودة في القاعدة والشاشة مش شايفاها — فشل صامت كامل.
--
-- ⚠️ ليه عمود `letter` مش اشتقاق من الكود:
--   حروف stock_flat (m/s/b/f) **اعتباطية**: seyouf بادئته «f» مش «s»
--   لأن «s» محجوزة لسان ستيفانو. يعني الحرف مالوش قاعدة تشتق منها،
--   فلازم يتخزّن. وده المكان الوحيد اللي يتحدّد فيه من الآن.
--
-- ملحوظة على النطاق:
--   refresh_stock_flat و get_stock_summary **صح للسيوف** بس لسه
--   بيكتبوا الفروع الأربعة بالإيد. ماتلمستهمش هنا عشان مالمسش حاجة
--   شغّالة في نفس الخطوة؛ تحويلهم للـletter بند مستقل.
--
--   وكمان: سلسلة الاستهلاك/الطلبيات (monthly_sales → get_consumption_rates
--   → consumption_flat → get_purchase_orders → purchase_orders_flat)
--   كلها ثلاثية لسه. مش في الترحيل ده — السيوف مالهاش أي مبيعات
--   أصلًا فمعدل استهلاكها صفر مهما عملنا. **بس لازم تتعمل قبل ما
--   الفرع يفتح ويبيع.** الدالتين تحت مكتوبين بحيث إن إضافة أعمدة
--   av_seyouf / surplus_seyouf بعدين **تشتغل لوحدها** من غير تعديل هنا.
-- ═══════════════════════════════════════════════════════════════════

-- ── ١) حرف الفرع ─────────────────────────────────────────────────
alter table public.branches add column if not exists letter text;

comment on column public.branches.letter is
  'بادئة أعمدة الفرع في stock_flat (m_q / s_q / b_q / f_q). اعتباطية — '
  'مش مشتقة من code (seyouf بادئته f لأن s محجوزة لـsan). '
  'أي فرع جديد لازم ياخد حرف هنا، والأعمدة تتعمل في stock_flat بنفس البادئة.';

update public.branches set letter = 'm' where code = 'mamora' and letter is null;
update public.branches set letter = 's' where code = 'san'    and letter is null;
update public.branches set letter = 'b' where code = 'bishr'  and letter is null;
update public.branches set letter = 'f' where code = 'seyouf' and letter is null;

-- حرفين متكررين = عمود فرع بيقرا بيانات فرع تاني بالساكت
create unique index if not exists branches_letter_uniq
  on public.branches (letter) where letter is not null;


-- ── ٢) الفروع اللي ليها حرف ───────────────────────────────────────
-- دالة مش view: `branches` مش من الجداول اللي المزامنة بتعمل لها
-- rename/drop، بس بنمشي على نفس العُرف عشان مايبقاش فيه استثناء
-- حد ينساه بعدين. راجع migrate_39 و no-views-on-swapped-tables.
create or replace function public.branch_letters()
returns table (code text, name text, letter text, sort_order int)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select b.code, b.name, b.letter, coalesce(b.sort_order, 999)
    from public.branches b
   where b.is_active
     and nullif(btrim(b.letter), '') is not null
   order by coalesce(b.sort_order, 999), b.name;
$fn$;

revoke all on function public.branch_letters() from public;
grant execute on function public.branch_letters() to anon, authenticated, service_role;


-- ── ٣) البحث السريع ──────────────────────────────────────────────
-- الأعمدة القديمة (m_q/s_q/b_q/m_p) **متسيبة زي ما هي** عشان
-- delivery/app.html الحالي مايقعش قبل ما يتعدّل. الجديد `q` فيه كل
-- الفروع، فالشاشة تتحوّل عليه في خطوة مستقلة ومن غير ترتيب إجباري.
drop function if exists public.quick_search_stock(text, integer);

create function public.quick_search_stock(p_q text, p_limit integer default 20)
returns table (
  code text, name text, company text, unit text, med integer,
  m_q numeric, s_q numeric, b_q numeric, m_p numeric,   -- قديمة: للتوافق
  q jsonb,                                              -- جديدة: كل الفروع
  sim real
)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_q text := btrim(coalesce(p_q, ''));
begin
  if length(v_q) < 2 then return; end if;
  perform set_limit(0.1);
  return query
    select f.itm_code, f.n, f.co, f.u, f.med,
           f.m_q, f.s_q, f.b_q, f.m_p,
           -- to_jsonb(f)->>(letter||'_q') = وصول للعمود بالاسم من غير
           -- dynamic SQL. فرع جديد بحرف وأعمدة في stock_flat بيظهر لوحده.
           (select jsonb_object_agg(bl.letter, jsonb_build_object(
                     'name', bl.name,
                     'sort', bl.sort_order,
                     'q',    coalesce((to_jsonb(f) ->> (bl.letter || '_q'))::numeric, 0),
                     'p',    coalesce((to_jsonb(f) ->> (bl.letter || '_p'))::numeric, 0)))
              from public.branch_letters() bl),
           greatest( similarity(ar_norm(f.n), ar_norm(v_q)),
                     case when f.itm_code = v_q then 1.0
                          when f.n ilike '%' || v_q || '%' then 0.9 else 0 end )::real
      from stock_flat f
     where ar_norm(f.n) % ar_norm(v_q)
        or f.n ilike '%' || v_q || '%'
        or f.itm_code ilike v_q || '%'
     -- ترتيب **بموضع العمود** (11 = sim) مش باسمه: في plpgsql أسماء
     -- أعمدة RETURNS TABLE بتبقى متغيّرات، فـ`order by sim` بيتحوّل
     -- للمتغيّر الفاضي ويلغي الترتيب بالساكت. الموضع مايتظلّلش.
     order by 11 desc, f.n
     limit greatest(1, least(p_limit, 40));
end $fn$;

-- الصلاحيات زي ما كانت بالحرف (PUBLIC + anon + authenticated).
-- ⚠️ مش بضيّقها هنا: ده قرار أمني مستقل وله خطة لوحدها
--    (SECURITY_HANDOFF.md)، ومش من شغل الترحيل ده.
grant execute on function public.quick_search_stock(text, integer)
  to public, anon, authenticated;


-- ── ٤) تنبيهات الحد الأدنى ───────────────────────────────────────
-- المفاتيح القديمة (min_m/qty_s/av_b/pend_m...) متسيبة للتوافق،
-- **ومشتقّة من نفس الكائن الجديد** عشان مايحصلش اختلاف بينهم لو
-- اتغيّر منطق. الجديد `br` مفاتيحه حروف الفروع.
create or replace function public.get_min_stock_alerts()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_role text := coalesce(public.jwt_app_role(), '');
  v_pg   text := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  v_rows jsonb;
  v_brs  jsonb;
begin
  if v_pg <> 'service_role' and v_role = '' then
    return jsonb_build_object('success', false, 'error', 'لازم تسجّل دخول');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', bl.code, 'name', bl.name, 'letter', bl.letter)
         order by bl.sort_order, bl.name), '[]'::jsonb)
    into v_brs from public.branch_letters() bl;

  with brn as (
    -- كل تهجئة ممكنة للفرع → حرفه. stock_limit.branch و
    -- order_selections.branch بيتكتبوا بأسماء بشرية («سيدى بشر» /
    -- «سيدي بشر»)، فالمطابقة بالاسم + الأسماء البديلة + تطبيع الياء.
    select distinct b.letter, replace(x, 'ي', 'ى') as nm
      from public.branches b,
           unnest(array[b.name] || coalesce(b.aliases, '{}'::text[])) x
     where b.is_active and nullif(btrim(b.letter), '') is not null
  ),
  items as (
    select sl.item_code,
           max(sl.item_name) filter (where nullif(btrim(sl.item_name), '') is not null) as item_name,
           max(sl.item_type) as item_type,
           max(sl.updated_at) as updated_at
      from stock_limit sl
     where sl.item_code is not null
     group by sl.item_code
  ),
  lim as (
    select sl.item_code, n.letter, max(sl.min_stock) as min_stock
      from stock_limit sl
      join brn n on n.nm = replace(btrim(sl.branch), 'ي', 'ى')
     where sl.item_code is not null
     group by sl.item_code, n.letter
  ),
  pend as (
    select os.itm_code, n.letter
      from order_selections os
      join brn n on n.nm = replace(btrim(os.branch), 'ي', 'ى')
     group by os.itm_code, n.letter
  ),
  per_item as (
    select i.item_code, i.item_name, i.item_type, i.updated_at,
           sf.n, sf.u, sf.co, sf.med,
           (select jsonb_object_agg(bl.letter, jsonb_build_object(
                     'name', bl.name,
                     'sort', bl.sort_order,
                     'min',  (select l.min_stock from lim l
                               where l.item_code = i.item_code and l.letter = bl.letter),
                     'qty',  coalesce((to_jsonb(sf) ->> (bl.letter || '_q'))::numeric, 0),
                     -- consumption_flat أعمدته بالكود مش بالحرف (av_mamora).
                     -- av_seyouf لسه ماتعملش → null → «—» في الشاشة،
                     -- وبيتملى لوحده يوم ما العمود يتضاف.
                     'av',   (to_jsonb(cf) ->> ('av_' || bl.code))::numeric,
                     'pend', exists (select 1 from pend p
                                      where p.itm_code = i.item_code and p.letter = bl.letter)))
              from public.branch_letters() bl) as br
      from items i
      left join stock_flat sf       on sf.itm_code = i.item_code
      left join consumption_flat cf on cf.code     = i.item_code
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.item_code,
           'name', coalesce(nullif(btrim(p.item_name), ''), p.n, p.item_code),
           'unit', p.u, 'company', p.co, 'med', p.med,
           'type', p.item_type,
           'br', p.br,
           -- مفاتيح قديمة، مشتقّة من br نفسه (مفيش منطق مكرر يتفارق)
           'min_m', (p.br -> 'm' ->> 'min')::numeric,
           'min_s', (p.br -> 's' ->> 'min')::numeric,
           'min_b', (p.br -> 'b' ->> 'min')::numeric,
           'qty_m', coalesce((p.br -> 'm' ->> 'qty')::numeric, 0),
           'qty_s', coalesce((p.br -> 's' ->> 'qty')::numeric, 0),
           'qty_b', coalesce((p.br -> 'b' ->> 'qty')::numeric, 0),
           'av_m',  (p.br -> 'm' ->> 'av')::numeric,
           'av_s',  (p.br -> 's' ->> 'av')::numeric,
           'av_b',  (p.br -> 'b' ->> 'av')::numeric,
           'pend_m', coalesce((p.br -> 'm' ->> 'pend')::boolean, false),
           'pend_s', coalesce((p.br -> 's' ->> 'pend')::boolean, false),
           'pend_b', coalesce((p.br -> 'b' ->> 'pend')::boolean, false),
           'updated_at', p.updated_at
         ) order by coalesce(nullif(btrim(p.item_name), ''), p.n)), '[]'::jsonb)
    into v_rows
    from per_item p;

  return jsonb_build_object(
    'success', true,
    'rows', v_rows,
    'branches', v_brs,              -- الشاشة تبني أعمدتها من ده
    'my_branch', public.jwt_branch(),
    'is_admin', v_role = 'admin',
    'stock_at', (select max(src_max) from stock_flat_meta));
end $fn$;

revoke all on function public.get_min_stock_alerts() from public, anon;
grant execute on function public.get_min_stock_alerts() to authenticated, service_role;

notify pgrst, 'reload schema';
