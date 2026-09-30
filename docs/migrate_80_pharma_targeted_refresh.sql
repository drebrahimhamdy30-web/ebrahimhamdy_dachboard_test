-- ═══════════════════════════════════════════════════════════════════
--  تحديث مستهدف لأسعار فارما — بالكود مش بالاسم
-- ═══════════════════════════════════════════════════════════════════
--  ليه دالة جديدة مش pharma_prices_upsert؟
--  الموجودة بتطابق على (item_name, store)، وده صح للجولة الكاملة
--  لأنها بتقرا الاسم من نفس فهرس فارما اللي الصفوف اتعملت منه. لكن
--  التحديث المستهدف بيبدأ من **كود المورّد** اللي مخزّن عندنا، وصفحة
--  المنتج بترجّع الاسم مختلف حرف أو حرفين (مسافات، «مجم» مقابل «مج»).
--  فلو كتبنا بالاسم كان هيعمل **صف جديد** بدل ما يحدّث الموجود.
--  الكود مفتاح دقيق: 21,180 كود مميّز في 21,181 صف.
--
--  مابيعملش insert خالص — صنف مش عندنا مايتضافش من هنا، وده مقصود:
--  ده تحديث لأسعار أصناف احنا بنطلبها، مش استيراد كتالوج.
--
--  التطبيق: السحابة (المصدر) + السيرفر الذاتي.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.pharma_prices_refresh(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  with incoming as (
    select distinct on (btrim(supplier_code))
           btrim(supplier_code) as supplier_code,
           price, discount_perc, available
      from jsonb_to_recordset(p_rows)
        as x(supplier_code text, price numeric, discount_perc numeric, available boolean)
     where coalesce(btrim(supplier_code), '') <> ''
       and price is not null
     order by btrim(supplier_code)
  ),
  up as (
    update store_item_prices s
       set price         = i.price,
           discount_perc = i.discount_perc,
           available     = coalesce(i.available, true),
           updated_at    = now()
      from incoming i
     where s.store = 'فارما اوفر سيز'
       and s.supplier_code = i.supplier_code
    returning 1
  )
  select count(*) into n from up;
  return n;
end
$$;

-- النداء جاي من الـedge function بمفتاح service_role — مش من المتصفح
--
-- ⚠️ `revoke from public` **لوحده مش كفاية على السيرفر الذاتي**: فيه
--    تريجر DDL بيدّي أي دالة جديدة صلاحية تنفيذ **لـanon وauthenticated
--    مباشرةً**، والـrevoke من PUBLIC مابيشيلش منحة مباشرة لدور معيّن.
--    اتأكد بالتجربة 2026-09-30: بعد الترحيل على الذاتي، نداء
--    rpc/pharma_prices_refresh بمفتاح anon رجّع 0 (يعني اشتغل) مش 403.
--    ومن غير الأسطر دي أي حد بالمفتاح العام يقدر يكتب أسعار فارما.
--    راجع [[selfhosted-wide-grants]].
revoke all on function public.pharma_prices_refresh(jsonb) from public;
revoke all on function public.pharma_prices_refresh(jsonb) from anon;
revoke all on function public.pharma_prices_refresh(jsonb) from authenticated;
grant execute on function public.pharma_prices_refresh(jsonb) to service_role;
