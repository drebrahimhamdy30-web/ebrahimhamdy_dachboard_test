-- ═══════════════════════════════════════════════════════════════════
--  تقرير تقييم العملاء: حارس الإصدار (أدمن فقط) + اسم المؤسسة للختم
-- ═══════════════════════════════════════════════════════════════════
--  الليه: التقرير فيه ترتيب وأسماء، ونسخة منه ممكن تتستخدم دعاية
--  شخصية. فالإصدار بقى مقصور على الأدمن، والحارس هنا على السيرفر مش
--  بإخفاء الزر — إخفاء الزر لوحده بيتلفّ من أدوات المتصفح.
--
--  والدالة كمان بترجّع اسم المؤسسة للعلامة المائية: لو الاسم اتقرا من
--  المتصفح (localStorage) كان ينفع حد يفضّيه قبل الطباعة فتطلع نسخة
--  بلا ختم. جاي من السيرفر يبقى جزء من شرط الإصدار نفسه.
--
--  مفيش جدول ولا تسجيل — الدالة قراءة بحتة.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.rating_report_gate()
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_role text  := public.jwt_app_role();
  v_name text  := btrim(coalesce(claims ->> 'full_name', claims -> 'app_metadata' ->> 'full_name', ''));
  v_org  text;
begin
  if not (coalesce(claims ->> 'role', '') = 'service_role' or v_role = 'admin') then
    raise exception 'إصدار التقرير مقصور على مدير النظام' using errcode = '42501';
  end if;

  select nullif(btrim(company_name), '') into v_org from public.org_settings where id = 1;

  return jsonb_build_object(
    'company',   coalesce(v_org, 'الصيدلية'),
    'issued_by', coalesce(nullif(v_name, ''), 'غير معروف'),
    'issued_at', now()
  );
end $function$;

revoke all on function public.rating_report_gate() from public;
grant execute on function public.rating_report_gate() to authenticated, service_role;

notify pgrst, 'reload schema';
