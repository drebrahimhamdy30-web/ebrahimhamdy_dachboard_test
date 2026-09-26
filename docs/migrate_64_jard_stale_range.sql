-- ═══════════════════════════════════════════════════════════════════
-- «لم يُجرد منذ مدة» بنطاق تاريخ (من / إلى) بدل عدد شهور
-- ═══════════════════════════════════════════════════════════════════
-- get_jard_stale(branch, months) بترجّع الأصناف اللي آخر جرد ليها أقدم من
-- N شهر. المالك عايز يحدّد **فترة**: «إيه اللي ما اتجردش من كذا لكذا»،
-- والافتراضي «إلى» = النهاردة.
--
-- الإصدار الجديد بياخد تاريخين وبيرجّع الأصناف اللي **مفيش ليها أي جرد
-- داخل الفترة** (مع اللي ما اتجردتش أبدًا)، ومعاها آخر جرد للعرض.
-- الإصدار القديم (months) سايبينه زي ما هو للتوافق.
--
-- ملاحظة: الأصناف بتتقرا من جداول المخزون لكل فرع (stock_<code>) بنفس
-- أسلوب الدالة الأصلية — جداول المخزون بتتعمل rename في المزامنة فممنوع
-- أي view عليها، والاستعلام بيتبني ديناميكيًا من جدول الفروع.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.get_jard_stale(p_branch text, p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
declare
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role text  := coalesce(claims ->> 'role', '');
  v_br    text;
  v_from  date  := coalesce(p_from, (now() at time zone 'Africa/Cairo')::date - 90);
  v_to    date  := coalesce(p_to,   (now() at time zone 'Africa/Cairo')::date);
  v_union text;
  out_j   jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;
  v_br := public.jard_canon_branch(p_branch);
  if v_br is null then
    return '[]'::jsonb;
  end if;
  if v_from > v_to then                        -- لو المستخدم عكس التاريخين
    select v_to, v_from into v_from, v_to;
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
    ),
    audited_in_range as (                       -- اتجرد جوّه الفترة = مش ناقص
      select distinct l.code
        from jard_audit_log l
       where l.branch = $1
         and (l.audited_at at time zone 'Africa/Cairo')::date between $2 and $3
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.last_audited nulls first), '[]'::jsonb)
      from (
        select s.itm_code as code, s.itm_name_ar, s.itm_name_en, s.sto_qty_big, al.last_audited
          from (%s) s
          left join audit_last al on al.code = s.itm_code
         where s.branch = $1
           and coalesce(nullif(s.sto_qty_big, ''), '0')::numeric > 0
           and not exists (select 1 from audited_in_range r where r.code = s.itm_code)
      ) t
  $q$, v_union)
  into out_j using v_br, v_from, v_to;

  return out_j;
end $function$;

COMMENT ON FUNCTION public.get_jard_stale(text,date,date) IS
  'أصناف الفرع اللي مفيش ليها أي جرد داخل الفترة (من/إلى) — ومعاها آخر جرد للعرض';

GRANT EXECUTE ON FUNCTION public.get_jard_stale(text,date,date) TO anon, authenticated;

COMMIT;
