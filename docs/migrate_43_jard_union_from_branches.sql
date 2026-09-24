-- ═══════════════════════════════════════════════════════════════════
-- get_jard_items / get_jard_stale: الـunion يتبني من branches
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- الـCTE كانت مكتوبة بالإيد في migrate_37 (بعد ما العرض v_branch_stock
-- وقّف المزامنة). دلوقتي بتتبني من branches وقت التشغيل، فالفرع الجديد
-- = صف في branches وبس.
--
-- لسه dynamic SQL مش view — نفس السبب: المزامنة بتعمل rename ثم drop.
--
-- ملاحظة للاختبار: حارس الدور بيقرا claim اسمه **user_role** (مش app_role):
--   select set_config('request.jwt.claims','{"user_role":"admin"}', false);
-- من غير كده الدالتين بيرجّعوا [] وتفتكر إن الاستعلام غلط.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.get_jard_items(p_branch text, p_category text)
returns jsonb language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role text  := coalesce(claims ->> 'role', '');
  v_br    text;
  v_cat   text := btrim(coalesce(p_category, ''));
  v_cycle integer;
  v_union text;
  out_j   jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;
  v_br := public.jard_canon_branch(p_branch);
  if v_br is null or v_cat = '' then
    return '[]'::jsonb;
  end if;

  select coalesce(s.cycle_days, 7) into v_cycle from jard_settings s where s.category = v_cat;
  v_cycle := coalesce(v_cycle, 7);

  select string_agg(
           format('select %L::text as branch, itm_code, itm_name_ar, itm_name_en, sto_qty_big from public.%I',
                  b.name, 'stock_' || b.code), ' union all ')
    into v_union
    from branches b
   where b.is_active
     and to_regclass('public.' || quote_ident('stock_' || b.code)) is not null;
  if v_union is null then return '[]'::jsonb; end if;

  execute format($q$
    select coalesce(jsonb_agg(to_jsonb(t) order by t.code), '[]'::jsonb)
      from (
        select distinct on (s.itm_code) s.itm_code as code, s.itm_name_ar, s.itm_name_en
          from (%s) s
         where s.branch = $1
           and coalesce(nullif(s.sto_qty_big, ''), '0')::numeric > 0
           and (case when $2 = 'fastmove'
                     then exists (select 1 from jard_fastmove_codes fc where fc.code = s.itm_code)
                     else exists (select 1 from jard_category_flags f
                                   where f.itm_code = s.itm_code and f.branch = $1 and f.category = $2)
                end)
           and not exists (
             select 1 from jard_audit_log l
              where l.code = s.itm_code and l.branch = $1 and l.category = $2
                and l.audited_at > now() - make_interval(days => $3))
         order by s.itm_code
      ) t
  $q$, v_union)
  into out_j using v_br, v_cat, v_cycle;

  return out_j;
end $fn$;

revoke all on function public.get_jard_items(text, text) from public, anon;
grant execute on function public.get_jard_items(text, text) to authenticated, service_role;


create or replace function public.get_jard_stale(p_branch text, p_months integer)
returns jsonb language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  v_br     text;
  v_months integer := greatest(coalesce(p_months, 3), 0);
  v_union  text;
  out_j    jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;
  v_br := public.jard_canon_branch(p_branch);
  if v_br is null then
    return '[]'::jsonb;
  end if;

  select string_agg(
           format('select %L::text as branch, itm_code, itm_name_ar, itm_name_en, sto_qty_big from public.%I',
                  b.name, 'stock_' || b.code), ' union all ')
    into v_union
    from branches b
   where b.is_active
     and to_regclass('public.' || quote_ident('stock_' || b.code)) is not null;
  if v_union is null then return '[]'::jsonb; end if;

  execute format($q$
    with audit_last as (
      select l.code, max(l.audited_at) as last_audited
        from jard_audit_log l where l.branch = $1 group by l.code
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.last_audited nulls first), '[]'::jsonb)
      from (
        select s.itm_code as code, s.itm_name_ar, s.itm_name_en, s.sto_qty_big, al.last_audited
          from (%s) s
          left join audit_last al on al.code = s.itm_code
         where s.branch = $1
           and coalesce(nullif(s.sto_qty_big, ''), '0')::numeric > 0
           and (al.last_audited is null
                or al.last_audited < now() - make_interval(months => $2))
      ) t
  $q$, v_union)
  into out_j using v_br, v_months;

  return out_j;
end $fn$;

revoke all on function public.get_jard_stale(text, integer) from public, anon;
grant execute on function public.get_jard_stale(text, integer) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- المقارنة قبل/بعد (السحابة 2026-09-24) — 12/12 متطابقين:
--   jard_items  المعمورة 26/100/567 · سان ستيفانو 26/110/682 · سيدى بشر 25/84/534
--   jard_stale  4024 · 3467 · 5133
-- ═══════════════════════════════════════════════════════════════════
