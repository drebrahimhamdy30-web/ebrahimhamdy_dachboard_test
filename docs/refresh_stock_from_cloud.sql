-- ═══════════════════════════════════════════════════════════════════
--  تحديث بيانات المخزون على السيرفر من السحابة
-- ═══════════════════════════════════════════════════════════════════
--  يتشغّل على **السيرفر** (supabase.ebrahimhamdy.com).
--
--  ليه محتاجينه:
--    n8n بيكتب المخزون على **السحابة مباشرة** (اتصال Postgres مباشر)،
--    فجداول stock_* على السيرفر مجمّدة من يوم النقل. أي شغل ظلّي
--    (migrate_15) هيقارن بيانات ميتة ويطلع نتيجة مالهاش معنى.
--
--  إزاي:
--    السيرفر لسه عنده سكيما cloudsrc = جداول السحابة عبر postgres_fdw
--    (اتعملت في migrate_01). فالتحديث = قراءة منها مباشرة، من غير
--    ملفات ولا رفع ولا تنزيل.
--
--  ⚠️ بيعمل truncate + إعادة تعبئة للجداول التلاتة. مافيش خطر على
--     السحابة — القراءة بس. الخطر الوحيد إنك تشغّله على السحابة
--     بالغلط، وساعتها هتمسح بيانات حيّة. **اتأكد إنك على السيرفر.**
--
--  ⚠️ لو السطر ده رجّع «السحابة» يبقى انت في المكان الغلط — اوقف.
-- ═══════════════════════════════════════════════════════════════════

-- حارس: بيوقف التنفيذ لو مفيش cloudsrc (يعني إنت مش على السيرفر)
do $guard$
begin
  if to_regclass('cloudsrc.stock_mamora') is null then
    raise exception '⛔ سكيما cloudsrc مش موجودة — يبدو إنك مش على السيرفر. اوقف.';
  end if;
end $guard$;

begin;

truncate public.stock_mamora;
insert into public.stock_mamora select * from cloudsrc.stock_mamora;

truncate public.stock_san;
insert into public.stock_san    select * from cloudsrc.stock_san;

truncate public.stock_bishr;
insert into public.stock_bishr  select * from cloudsrc.stock_bishr;

commit;

-- المفروض الأعداد تطابق السحابة وقت التشغيل
select 'المعمورة' as الفرع, count(*) as صفوف,
       to_char(max(updated_at) at time zone 'Africa/Cairo','MM-DD HH24:MI') as آخر_تحديث
from public.stock_mamora
union all select 'سان ستيفانو', count(*),
       to_char(max(updated_at) at time zone 'Africa/Cairo','MM-DD HH24:MI') from public.stock_san
union all select 'سيدى بشر', count(*),
       to_char(max(updated_at) at time zone 'Africa/Cairo','MM-DD HH24:MI') from public.stock_bishr;
