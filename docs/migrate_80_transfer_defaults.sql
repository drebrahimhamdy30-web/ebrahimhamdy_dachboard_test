-- ═══════════════════════════════════════════════════════════════════
-- التحويلات: فرع افتراضي لكل فرع + فحص توفّر الصنف قبل الطلب
-- ═══════════════════════════════════════════════════════════════════
-- شاشة «طلب جديد ← تحويل» كانت بتسيب قائمة «طلب تحويل من فرع» فاضية،
-- فالموظف بيختار بالتخمين — ممكن يطلب من فرع الصنف مش عنده أصلاً.
--
-- دلوقتي:
--   • لكل فرع «فرع افتراضي» بيطلب منه (يتظبط من إعدادات المؤسسة).
--   • مفتاح تفعيل عام للميزة.
--   • دالة بترجّع رصيد الصنف في **كل الفروع** في نداء واحد، فالشاشة
--     تقدر تقول: متوفر فين ومش متوفر فين قبل ما الطلب يتبعت.
--
-- ⚠️ الرصيد من جداول المخزون عندنا (stock_<code>) — بتتحدّث مع مزامنة
--    n8n، يعني رصيد آخر مزامنة مش لحظي. ده قرار مقصود: نداء واحد سريع
--    بدل 4 نداءات على eplus.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ ① الفرع الافتراضي لكل فرع ═══
ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS transfer_default_branch_id uuid REFERENCES public.branches(id);

COMMENT ON COLUMN public.branches.transfer_default_branch_id IS
  'الفرع اللي الفرع ده بيطلب منه التحويلات افتراضيًا (إعدادات المؤسسة)';

-- ═══ ② مفتاح التفعيل ═══
ALTER TABLE public.org_settings
  ADD COLUMN IF NOT EXISTS transfer_defaults_enabled boolean NOT NULL DEFAULT false;

-- ═══ ③ القيم الأولية زي ما اتفقنا (وتتغيّر من الشاشة) ═══
--     المعمورة ↔ سيدى بشر   ·   سان ستيفانو ↔ السيوف
UPDATE public.branches b SET transfer_default_branch_id = t.id
  FROM public.branches t
 WHERE b.transfer_default_branch_id IS NULL
   AND ((b.name = 'المعمورة'     AND t.name = 'سيدى بشر')
     OR (b.name = 'سيدى بشر'     AND t.name = 'المعمورة')
     OR (b.name = 'سان ستيفانو' AND t.name = 'السيوف')
     OR (b.name = 'السيوف'       AND t.name = 'سان ستيفانو'));

-- ═══ ④ رصيد الصنف في كل الفروع — نداء واحد ═══
CREATE OR REPLACE FUNCTION public.item_branch_stock(p_code text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_code  text := btrim(coalesce(p_code, ''));
  v_union text;
  out_j   jsonb;
BEGIN
  IF v_code = '' THEN RETURN '[]'::jsonb; END IF;

  SELECT string_agg(
           format('select %L::uuid as branch_id, %L::text as branch, itm_code, itnl_code, itm_name_ar, sto_qty_big from public.%I',
                  b.id, b.name, 'stock_' || b.code), ' union all ')
    INTO v_union
    FROM branches b
   WHERE b.is_active
     AND to_regclass('public.' || quote_ident('stock_' || b.code)) IS NOT NULL;
  IF v_union IS NULL THEN RETURN '[]'::jsonb; END IF;

  EXECUTE format($q$
    SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.qty DESC), '[]'::jsonb)
      FROM (
        SELECT s.branch_id, s.branch,
               max(s.itm_name_ar) AS itm_name_ar,
               coalesce(sum(CASE WHEN s.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$'
                                 THEN s.sto_qty_big::numeric ELSE 0 END), 0) AS qty
          FROM (%s) s
         WHERE btrim(s.itm_code) = $1 OR btrim(s.itnl_code) = $1
         GROUP BY s.branch_id, s.branch
      ) t
  $q$, v_union) INTO out_j USING v_code;

  RETURN coalesce(out_j, '[]'::jsonb);
END $fn$;

GRANT EXECUTE ON FUNCTION public.item_branch_stock(text) TO anon, authenticated;

COMMIT;
