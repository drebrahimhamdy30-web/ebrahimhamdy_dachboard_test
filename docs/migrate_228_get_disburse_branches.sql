/* migrate_228 — الشاشة تقرا فروع الصرف من الإعداد مش من الكود

   بعد migrate_227 بقى الحارس على السيرفر، بس الشاشة لسه فيها
   `const DISBURSE_BRANCHES = ['mamora']` مكتوبة في الكود. يعني مصدرين
   للحقيقة: لو المالك فعّل فرع من الإعدادات، السيرفر هيسمح والشاشة
   مش هتعرض — ومحدش هيفهم ليه.

   الدالة دي بترجّع نفس القايمة عشان الشاشة تقرا منها. مش معلومة حسّاسة
   (أكواد فروع)، فمتاحة لأي مستخدم مسجّل. */

create or replace function public.get_disburse_branches()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(
           (select to_jsonb(o.disburse_branches) from public.org_settings o where o.id = 1),
           '["mamora"]'::jsonb);
$function$;

comment on function public.get_disburse_branches() is
  'أكواد الفروع المفعّل فيها الصرف التلقائي (org_settings.disburse_branches). الشاشة بتقرا منها بدل قايمة مكتوبة في الكود. الحارس الحقيقي في enqueue_wallet_disbursement.';

revoke all on function public.get_disburse_branches() from public, anon;
grant execute on function public.get_disburse_branches() to authenticated, service_role;
