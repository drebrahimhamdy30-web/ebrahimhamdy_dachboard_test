import { createClient } from 'npm:@supabase/supabase-js@2'

/* ═══════════════════════════════════════════════════════════════════
   تنبيهات الطيار — التطبيق بيندهها كل كام ثانية
   ═══════════════════════════════════════════════════════════════════
   ⚠️ السر مايتكتبش في الكود — الريبو ده عام. مخزّن في vault.
      القيمة **ماتغيرتش**: نفس السر اللي جوه الـAPK المنشور، فتغييرها
      محتاج إصدار جديد. اللي اتعمل هنا إنها طلعت من الملف عشان الدالة
      تنفع تتصدّر للريبو من غير ما تسرّبه.

   ⚠️ سر فاضي = رفض (مفيش تنبيهات)، مش سماح للكل. القيمة مخزّنة في
      الذاكرة دقيقة عشان مانقراش vault مع كل نداء (التطبيق بينده كتير).
   ═══════════════════════════════════════════════════════════════════ */

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

let _sec: { v: string; exp: number } | null = null
async function appSecret(): Promise<string> {
  const now = Date.now()
  if (_sec && _sec.exp > now) return _sec.v
  const { data } = await supabase.rpc('vault_secret', { p_name: 'driver_app_secret' })
  const v = typeof data === 'string' ? data : ''
  // لو القراية فشلت مانخزنش فاضي دقيقة — نجرّب تاني في النداء اللي بعده
  if (v) _sec = { v, exp: now + 60_000 }
  return v
}

Deno.serve(async (req) => {
  let p: any
  try { p = await req.json() } catch { return json({ events: [] }) }
  const secret = await appSecret()
  if (!secret || p.secret !== secret || !p.driver_id) return json({ events: [] })
  const driverId = p.driver_id
  const ack: number[] = Array.isArray(p.ack) ? p.ack : []

  // تأكيد استلام التنبيهات اللي التطبيق عرضها
  if (ack.length) {
    await supabase.from('driver_events')
      .update({ delivered_at: new Date().toISOString() })
      .in('id', ack).is('delivered_at', null)
  }

  // التنبيهات المعلّقة
  const { data } = await supabase.from('driver_events')
    .select('id,type,title,body,order_id,created_at')
    .eq('driver_id', driverId).is('delivered_at', null)
    .order('id', { ascending: true }).limit(20)

  return json({ events: data ?? [] })
})

function json(b: unknown) {
  return new Response(JSON.stringify(b), { status: 200, headers: { 'Content-Type': 'application/json' } })
}
