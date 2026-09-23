-- ═══════════════════════════════════════════════════════════════════
-- get_jard_erp: فلترة بالفرع والتبويب في القاعدة بدل المتصفح
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**: السحابة والسيرفر الذاتي)
--
-- ليه:
--   الدالة كانت بترجّع كل صفوف jard_erp (5963 صف) والشاشة بتفلتر بعدها
--   في المتصفح على التبويب والفرع. التوزيع الحقيقي:
--
--     مرتجعات  المعمورة 1442 · سان ستيفانو 477 · سيدى بشر 470
--     غوالى    المعمورة  846 · سان ستيفانو 1051 · سيدى بشر 726
--     erp      المعمورة  360 · سان ستيفانو  197 · سيدى بشر 177
--     تلاجه    المعمورة  102 · سان ستيفانو  112
--
--   يعني موظف سيدى بشر على تبويب erp محتاج 177 صف وبينزّل 5963 — 33 ضعف.
--
-- الباراميترين اختياريين (default null) عشان النداء القديم بـ{} يفضل
-- شغّال ويرجّع الكل — الأدمن على «كل الفروع» بيستعمل ده.
--
-- ⚠️ النسخة القديمة get_jard_erp() بلا باراميترات **لازم تتشال**، وإلا
--    PostgREST يلاقي نسختين وينادي الغلط أو يرفض للالتباس.
-- ═══════════════════════════════════════════════════════════════════

drop function if exists public.get_jard_erp();

create or replace function public.get_jard_erp(
  p_branch text default null,
  p_type   text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role text  := coalesce(claims ->> 'role', '');
  v_br    text  := nullif(btrim(coalesce(p_branch, '')), '');
  v_type  text  := nullif(btrim(coalesce(p_type,   '')), '');
  out_j   jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;

  -- اسم الفرع القياسي لو اتبعت؛ لو الفرع مش معروف نرجّع فاضي بدل الكل
  if v_br is not null then
    v_br := public.jard_canon_branch(v_br);
    if v_br is null then
      return '[]'::jsonb;
    end if;
  end if;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]'::jsonb)
    into out_j
    from (
      select e.id, e.code, e.branch, e.type, e.itm_name_ar, e.itm_name_en,
             e.bill_no, e.bill_date as "time", e.qty, e.sell_price,
             e.unit_ar, e.unit_en, e.skip, e.done, e.mismatch,
             e.actual_balance, e.system_balance, e.action_time
        from jard_erp e
       -- ى/ي: نفس التطبيع المستعمل في باقي الدوال
       where (v_br   is null or replace(e.branch, 'ي', 'ى') = replace(v_br, 'ي', 'ى'))
         and (v_type is null or lower(coalesce(e.type, '')) = lower(v_type))
    ) t;

  return out_j;
end $fn$;

revoke all on function public.get_jard_erp(text, text) from public, anon;
grant execute on function public.get_jard_erp(text, text) to authenticated, service_role;
