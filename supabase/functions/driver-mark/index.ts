import { createClient } from 'npm:@supabase/supabase-js@2'

/* ═══════════════════════════════════════════════════════════════════
   تسجيل تشخيصي من تطبيق الطيار → جدول driver_debug
   ═══════════════════════════════════════════════════════════════════
   ⚠️ **مفيش أي مصادقة هنا.** أي حد يقدر يبعت JSON ويتكتب في القاعدة
      بمفتاح service_role. الخطورة محدودة (تلويث سجلات مش تسريب)، بس
      لازم تتقفل.

   ماتضفش حراسة قبل إصدار APK جديد: التطبيق الحالي بيبعت الجسم من غير
   أي سر (phalix-driver-app/lib/api.dart → Api.debug)، فالحراسة دلوقتي
   هتوقف تسجيل التشخيص من غير ما حد ياخد باله.

   الحل مع أول إصدار: التطبيق يبعت السر، والدالة تقراه من vault زي
   driver-poll بالظبط.
   ═══════════════════════════════════════════════════════════════════ */

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

Deno.serve(async (req) => {
  let b: any = {}
  try { b = await req.json() } catch { /* ignore */ }
  try { await supabase.from('driver_debug').insert({ event: b.event ?? 'alarm', payload: b }) } catch (_) {}
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'Content-Type': 'application/json' } })
})
