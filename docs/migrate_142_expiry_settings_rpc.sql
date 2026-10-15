/* ═══════════════════════════════════════════════════════════════════
   إعدادات «قرب انتهاء الصلاحية» من شاشة إعدادات المؤسسة
   ═══════════════════════════════════════════════════════════════════
   دالة واحدة بتكتب الاتنين مع بعض:
     • `purchase_settings.expiry_months` — نافذة الترشيح بالشهور
     • `sync_jobs.item_expiry` — كل كام ساعة تتسحب التواريخ من الفروع

   ليه RPC ومش PATCH من الشاشة؟ `sync_jobs` مقفول على `authenticated`
   قراءة بس (الجدول بيسوق محرّك على جهاز الصيدلية — تعديله مش حق أي
   حساب داخل). فالحراسة على السيرفر بـ`require_app_role`، مش بإخفاء
   الزر.

   وبتعيد بناء الطلبيات بـ`p_force` في نفس النداء: من غير كده
   المالك بيغيّر الرقم وما يشوفش فرق — زي اللي حصل بالظبط وقت
   الاختبار قبل ما البصمة تتصلّح في migrate_140.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.set_expiry_settings(
  p_months  integer,
  p_hours    integer default null,
  p_enabled  boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare v jsonb;
begin
  perform public.require_app_role(array['admin','manager']);

  if p_months is null or p_months < 1 or p_months > 36 then
    raise exception 'شهور الصلاحية لازم تكون بين 1 و36';
  end if;
  if p_hours is not null and (p_hours < 1 or p_hours > 168) then
    raise exception 'ساعات المزامنة لازم تكون بين 1 و168';
  end if;

  update public.purchase_settings
     set expiry_months = p_months, updated_at = now()
   where id = 1;

  update public.sync_jobs
     set interval_minutes = coalesce(p_hours * 60, interval_minutes),
         enabled          = coalesce(p_enabled, enabled),
         updated_at       = now()
   where id = 'item_expiry';

  perform public.refresh_purchase_orders(true);

  select jsonb_build_object(
           'months',   (select expiry_months from public.purchase_settings where id = 1),
           'hours',    (select interval_minutes / 60 from public.sync_jobs where id = 'item_expiry'),
           'enabled',  (select enabled          from public.sync_jobs where id = 'item_expiry'),
           'last_run', (select last_run_at      from public.sync_jobs where id = 'item_expiry'),
           'candidates', (select count(*) from public.purchase_orders_flat where exp_branch is not null))
    into v;
  return v;
end
$fn$;

revoke all on function public.set_expiry_settings(integer, integer, boolean) from public, anon;
grant execute on function public.set_expiry_settings(integer, integer, boolean) to authenticated, service_role;
