-- ═══════════════════════════════════════════════════════════════════
-- خطوة 9: عزل السيرفر عن الشغل الحقيقي  ⚠️ **مهمة جدًا**
-- ═══════════════════════════════════════════════════════════════════
-- شغّله على **السيرفر** (supabase.ebrahimhamdy.com) — مش على السحابة.
--
-- ⚠️⚠️ الخطر: جدول driver_fcm_tokens اتنقل، يعني **توكنات تليفونات
--   الطيارين الحقيقيين موجودة على السيرفر**. أول ما دوال Edge تتنشر،
--   أي تعديل على طلب في التست هيبعت **إشعار حقيقي على تليفون طيار
--   شغّال دلوقتي**. وده يربك الطيار ويخليه يفتح طلب مش بتاعه.
--
--   وتريجرات الأداء بتنده Google Maps — يعني **فلوس** على حصة الحساب،
--   ونتايج محسوبة على بيانات لقطة قديمة.
--
-- الملف ده بيعطّل الأربعة دول **بس**. كل حاجة تانية بتفضل شغّالة عادي
-- عشان القياس يبقى واقعي.
--
-- ⚠️ يوم التحويل الحقيقي: شغّل القسم الأخير (معلَّق) عشان ترجّعهم.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1) تعطيل التريجرات ذات الأثر الخارجي ────────────────────────
alter table public.orders disable trigger trg_notify_fcm_on_assign;     -- 📱 إشعار FCM
alter table public.orders disable trigger trg_notify_on_driver_change;  -- 📱 إشعار FCM
alter table public.orders disable trigger trg_fail_perf;                -- 💰 Google Maps
alter table public.trips  disable trigger trip_return_perf_trg;         -- 💰 Google Maps

-- trg_delivery_perf لو موجود بنفس الاسم
do $$
begin
  alter table public.orders disable trigger trg_delivery_perf;
exception when others then null;
end $$;

-- ── 2) حزام أمان تاني: تفضية توكنات التليفونات ──────────────────
--    حتى لو حد فعّل تريجر بالغلط، مفيش تليفون يتبعتله.
--    (الجدول هيتملى لوحده لما التطبيق يتصل بالسيرفر يوم التحويل.)
delete from public.driver_fcm_tokens;

-- ── 3) تأكيد إن مفيش cron شغّال ─────────────────────────────────
--    الكرونات مااتنقلتش أصلًا، بس نتأكد: eplus_sync و pharma_sync
--    بيضربوا **أنظمة خارجية** — تشغيلهم من السيرفر يعني ضغط مضاعف
--    على eplus وعلى API فارما، وده بيأثر على الشغل الحقيقي.
do $$
declare r record; n int := 0;
begin
  if exists (select 1 from pg_namespace where nspname='cron') then
    for r in select jobid, jobname from cron.job loop
      perform cron.unschedule(r.jobid); n := n + 1;
    end loop;
  end if;
  raise notice 'مهام cron اتوقفت: %', n;
end $$;

-- ── 4) التحقق ───────────────────────────────────────────────────
select 'تريجرات خارجية شغّالة' as البند,
       coalesce(string_agg(t.tgname, ', '), '✅ ولا واحد') as النتيجة
from pg_trigger t
join pg_class cl on cl.oid = t.tgrelid
join pg_namespace n on n.oid = cl.relnamespace
join pg_proc p on p.oid = t.tgfoid
where n.nspname='public' and not t.tgisinternal and t.tgenabled <> 'D'
  and p.prosrc ~ 'net\.http_post|net\.http_get|functions/v1'
union all
select 'توكنات تليفونات على السيرفر', count(*)::text from public.driver_fcm_tokens
union all
select 'مهام cron', coalesce((select count(*)::text from cron.job), '0');


-- ═══════════════════════════════════════════════════════════════════
-- 🔓 يوم التحويل الحقيقي — شغّل ده (مش دلوقتي)
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ قبل ما تشغّله: تأكد إن السحابة **وقفت** (تريجراتها متعطّلة أو
--    البرودكشن اتحوّل)، وإلا الطيار هياخد الإشعار **مرتين** من
--    السيرفرين مع بعض.
--
-- alter table public.orders enable trigger trg_notify_fcm_on_assign;
-- alter table public.orders enable trigger trg_notify_on_driver_change;
-- alter table public.orders enable trigger trg_fail_perf;
-- alter table public.trips  enable trigger trip_return_perf_trg;
-- do $$ begin alter table public.orders enable trigger trg_delivery_perf;
--       exception when others then null; end $$;
--
-- ثم أعد جدولة الكرونات من cloudsrc.v_migration_post:
-- do $$
-- declare r record;
-- begin
--   for r in select ddl from cloudsrc.v_migration_post where kind='cron' loop
--     execute replace(r.ddl, '__TARGET_URL__', 'https://supabase.ebrahimhamdy.com');
--   end loop;
-- end $$;
