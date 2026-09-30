-- ═══════════════════════════════════════════════════════════════════
--  pharma_sync_tick: يبعت Authorization كمان مش x-sync-key بس
-- ═══════════════════════════════════════════════════════════════════
--  الحكاية: بوابة الـEdge Functions بترفض النداء بـ401
--  (UNAUTHORIZED_NO_AUTH_HEADER) قبل ما يوصل لكود الدالة أصلًا، لو
--  العلم verify_jwt=true. والعلم ده **بيرجع true تلقائيًا مع كل نشرة
--  جديدة للدالة** — يعني الاعتماد على إطفائه من لوحة التحكم هشّ: أول
--  تحديث للكود بيكسر الكرون في صمت.
--
--  وأسوأ حاجة إن الفشل ده **مش بيظهر في pharma_sync_log**: الرفض
--  بيحصل عند البوابة فالكود مابيشتغلش عشان يسجّل، و`running_since`
--  بتفضل متسجّلة لحد ما الـ25 دقيقة تعدّي. العطل الوحيد اللي بيبان
--  هو إن الأسعار وقفت تتحدّث — من غير أي أثر في السجل.
--
--  الحل: الكرون يبعت مفتاح anon في Authorization. المفتاح ده **عام
--  أصلًا** وموجود في config.js — الحراسة الحقيقية هي x-sync-key اللي
--  بيتفحص جوّه الدالة بـ is_pharma_sync_key. وبنقراه من vault مش من
--  الكود، لأن الريبو عام والهوك بيرفض أي JWT كامل في ملف.
--
--  متطلّب قبل التشغيل — سر في vault اسمه `gateway_anon_key`:
--    select vault.create_secret('<مفتاح anon من config.js>',
--             'gateway_anon_key', 'مفتاح anon لبوابة الدوال');
--
--  ⚠️ الـurl تحت بتاع السحابة. على السيرفر الذاتي عدّله.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.pharma_sync_tick()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare st public.pharma_sync_state; k text; ak text; rid bigint;
begin
  select * into st from public.pharma_sync_state where id = 1;
  if not st.enabled then return 'disabled'; end if;
  if st.running_since is not null and st.running_since > now() - interval '25 minutes' then
    return 'busy_since_' || st.running_since::text;
  end if;
  select decrypted_secret into k  from vault.decrypted_secrets where name = 'pharma_sync_key';
  if k is null then return 'no_key'; end if;
  -- من غيره البوابة بترفض بـ401 والكود مابيشتغلش خالص
  select decrypted_secret into ak from vault.decrypted_secrets where name = 'gateway_anon_key';
  if ak is null then return 'no_anon_key'; end if;

  update public.pharma_sync_state set running_since = now(), last_tick_at = now() where id = 1;
  select net.http_post(
    url := 'https://rxtjoqulmgkkcohmgzgi.supabase.co/functions/v1/pharma_sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || ak,
      'apikey', ak,
      'x-sync-key', k
    ),
    body := jsonb_build_object('scheduled', true),
    timeout_milliseconds := 180000
  ) into rid;
  return 'queued:' || rid;
end
$$;
