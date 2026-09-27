-- ═══════════════════════════════════════════════════════════════════
-- تقرير: كود واحد عليه أكتر من اسم صنف
-- ═══════════════════════════════════════════════════════════════════
-- في eplus ممكن نفس الكود يتحطّ على أكتر من صنف (مثال: 90003806 عليه
-- «فيونا مناديل فاميلي ابيض» و«اسود» و«طاردة للناموس» بسعرين مختلفين).
-- الكتالوج نفسه مش متخزّن عندنا — إحنا بنستورد أرصدة المخزون والمبيعات
-- والجرد. فالكشف بيتم على كل مصدر فيه (كود + اسم) عندنا:
--     • مخزون الفرع  stock_<code>      (الاسم الحالي)
--     • المبيعات     sales_items       (اسم الصنف وقت كل بيعة)
--     • الجرد        jard_audit_log    (اسم الصنف وقت الجرد)
--     • أصناف الجرد  jard_erp
-- ولو الكود ظهر بأكتر من اسم في أي منهم → بيطلع في التقرير مع مصادره.
--
-- المقارنة بتتجاهل فروق الكتابة (مسافات · ي/ى · أ/إ/ا · ة/ه) عشان
-- «مومنتا» و«مومينتا» ما يتعدّوش تعارض. اللي بيتعرض هو الأسماء الأصلية.
--
-- ⚠️ الكود اللي مكرّر في الكتالوج ومالهوش أي حركة (لا بيع ولا جرد ولا
--    رصيد) مستحيل نشوفه من هنا — ده محتاج تصدير شاشة الأصناف من eplus.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- تطبيع اسم الصنف للمقارنة (مش للعرض)
CREATE OR REPLACE FUNCTION public.item_name_key(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  select regexp_replace(
           translate(lower(btrim(coalesce(p_name,''))), 'يإأآةى', 'ىااااى'),
           '[\s\-_.]+', '', 'g');
$fn$;

CREATE OR REPLACE FUNCTION public.get_code_name_conflicts(p_branch text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
declare
  v_name  text;   -- اسم الفرع القياسي
  v_code  text;   -- كود الفرع (mamora …)
  v_alias text;   -- اسمه في eplus/المبيعات (الصيدلية …)
  v_sql   text;
  out_j   jsonb;
begin
  select b.name, b.code, coalesce(b.aliases[1], b.name)
    into v_name, v_code, v_alias
    from branches b
   where b.is_active
     and (replace(b.name,'ي','ى') = replace(coalesce(p_branch,''),'ي','ى')
          or b.code = p_branch)
   limit 1;
  if v_code is null then
    select b.name, b.code, coalesce(b.aliases[1], b.name)
      into v_name, v_code, v_alias
      from branches b where b.is_active order by b.sort_order limit 1;
  end if;
  if to_regclass('public.' || quote_ident('stock_' || v_code)) is null then
    return '[]'::jsonb;
  end if;

  v_sql := format($q$
    with src as (
      select btrim(itm_code) code, btrim(itm_name_ar) nm, 'المخزون' src
        from public.%I where coalesce(btrim(itm_code),'') <> '' and coalesce(btrim(itm_name_ar),'') <> ''
      union all
      select btrim(itm_code), btrim(itm_name_ar), 'المبيعات'
        from public.sales_items
       where store_name = $2 and coalesce(btrim(itm_code),'') <> '' and coalesce(btrim(itm_name_ar),'') <> ''
      union all
      select btrim(code), btrim(itm_name_ar), 'الجرد'
        from public.jard_audit_log
       where branch = $1 and coalesce(btrim(code),'') <> '' and coalesce(btrim(itm_name_ar),'') <> ''
      union all
      select btrim(code), btrim(itm_name_ar), 'أصناف الجرد'
        from public.jard_erp
       where coalesce(btrim(code),'') <> '' and coalesce(btrim(itm_name_ar),'') <> ''
    ),
    u as (
      select code, nm, public.item_name_key(nm) k, string_agg(distinct src, ' · ') srcs, count(*) hits
        from src group by code, nm, public.item_name_key(nm)
    ),
    conflict as (
      select code from u group by code having count(distinct k) > 1
    )
    select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
      select jsonb_build_object(
               'code',  u.code,
               'names', jsonb_agg(jsonb_build_object('name', u.nm, 'src', u.srcs, 'hits', u.hits)
                                  order by u.hits desc),
               'count', count(*),
               'stock_name', (select s.itm_name_ar from public.%I s where btrim(s.itm_code) = u.code limit 1),
               'qty',        (select coalesce(nullif(s.sto_qty_big,''),'0') from public.%I s where btrim(s.itm_code) = u.code limit 1),
               -- الأرقام في الأسماء مختلفة = غالبًا صنفين مختلفين فعلًا (حجم/عدد)
               'digits_differ', (count(distinct regexp_replace(u.nm,'[^0-9]','','g')) > 1)
             ) x
        from u join conflict c on c.code = u.code
       group by u.code
    ) t
  $q$, 'stock_' || v_code, 'stock_' || v_code, 'stock_' || v_code);

  execute v_sql into out_j using v_name, v_alias;
  return coalesce(out_j, '[]'::jsonb);
end $function$;

COMMENT ON FUNCTION public.get_code_name_conflicts(text) IS
  'أكواد ظهرت بأكتر من اسم صنف في مخزون الفرع أو مبيعاته أو جرده — مع مصدر كل اسم';

GRANT EXECUTE ON FUNCTION public.item_name_key(text)            TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_code_name_conflicts(text)  TO anon, authenticated;

COMMIT;
