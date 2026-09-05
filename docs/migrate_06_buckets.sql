-- ═══════════════════════════════════════════════════════════════════
-- خطوة 6: buckets التخزين
-- ═══════════════════════════════════════════════════════════════════
-- الجرد بيّن إن الملفات الفعلية **واحد** بس:
--
--   db-backups  3937 ملف / 267 ميجا  → ❌ مش هنقلها. دي نسخ احتياطية
--                                        للسحابة، السيرفر مالوش لازمة
--                                        بيها وهياخد نسخه بنفسه بعدين.
--   driver-apk  ملف واحد / 19 ميجا    → يترفع يدويًا لو احتجناه
--   branding    فاضي                  → الهوية مش مخزّنة كملف
--
-- فالمطلوب هنا: نعمل الـbuckets بنفس الإعدادات عشان أي كود بيشير لها
-- ماينكسرش. الملفات نفسها اختيارية.
--
-- ⚠️ سياسات storage.objects بتتنقل مع باقي السياسات في خطوة 1، فمش
--    محتاجة حاجة هنا.
-- ═══════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types, avif_autodetection)
values
  ('branding',   'branding',   true,  null,      null, false),
  ('db-backups', 'db-backups', false, null,      null, false),
  ('driver-apk', 'driver-apk', true,  209715200, null, false)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types,
      avif_autodetection = excluded.avif_autodetection;

select id as الـbucket,
       case when public then 'عام' else 'خاص' end as النوع,
       coalesce(file_size_limit::text, '—') as حد_الحجم,
       (select count(*) from storage.objects o where o.bucket_id = b.id) as ملفات
from storage.buckets b order by id;
