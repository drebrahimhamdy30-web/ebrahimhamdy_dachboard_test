import { createClient } from 'npm:@supabase/supabase-js@2'

/* ═══════════════════════════════════════════════════════════════════
   إشعارات Firebase للطيار — بتتنادى من تريجر notify_fcm_on_assign
   على جدول orders (إسناد طلب أو سحبه).
   ═══════════════════════════════════════════════════════════════════
   ⚠️ محتاجة متغيّر البيئة FCM_SERVICE_ACCOUNT — ملف JSON كامل لحساب
      خدمة Firebase (فيه private_key). من غيره الدالة بترجّع sent=0
      بهدوء ومفيش إشعارات تتبعت **من غير أي خطأ ظاهر**.
      اضبطه في: Edge Functions → Secrets.
   ═══════════════════════════════════════════════════════════════════ */

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)
const SA = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT') ?? '{}')

function b64url(u: Uint8Array): string {
  let s = ''
  for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i])
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function importPrivateKey(pem: string) {
  const b = pem.replace(/-----BEGIN PRIVATE KEY-----/, '')
               .replace(/-----END PRIVATE KEY-----/, '')
               .replace(/\s+/g, '')
  const der = Uint8Array.from(atob(b), c => c.charCodeAt(0))
  return await crypto.subtle.importKey('pkcs8', der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
}

let _tok: { v: string; e: number } | null = null
async function getAccessToken() {
  const now = Math.floor(Date.now() / 1000)
  if (_tok && _tok.e > now + 60) return _tok.v
  const h = { alg: 'RS256', typ: 'JWT' }
  const c = {
    iss: SA.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: SA.token_uri, iat: now, exp: now + 3600
  }
  const si = `${b64url(new TextEncoder().encode(JSON.stringify(h)))}.${b64url(new TextEncoder().encode(JSON.stringify(c)))}`
  const k = await importPrivateKey(SA.private_key)
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', k, new TextEncoder().encode(si)))
  const jwt = `${si}.${b64url(sig)}`
  const r = await fetch(SA.token_uri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`
  })
  const d = await r.json()
  _tok = { v: d.access_token, e: now + 3500 }
  return d.access_token
}

async function sendToDriver(driverId: string, title: string, body: string): Promise<number> {
  if (!SA.client_email) return 0
  const { data: tokens } = await supabase.from('driver_fcm_tokens').select('token').eq('driver_id', driverId)
  if (!tokens || tokens.length === 0) return 0
  let at: string
  try { at = await getAccessToken() } catch (e) { console.error('token err', (e as Error).message); return 0 }
  let sent = 0
  for (const t of tokens) {
    try {
      const res = await fetch(`https://fcm.googleapis.com/v1/projects/${SA.project_id}/messages:send`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${at}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: { token: t.token, data: { title, body }, android: { priority: 'HIGH', ttl: '0s' } } }),
      })
      if (res.ok) { sent++ }
      else {
        const txt = await res.text()
        // توكن ميت = نشيله بدل ما نفضل نجرّب عليه كل مرة
        if (res.status === 404 || txt.includes('registration-token-not-registered') || txt.includes('UNREGISTERED'))
          await supabase.from('driver_fcm_tokens').delete().eq('token', t.token)
        console.error('FCM failed', res.status, txt)
      }
    } catch (e) { console.error('FCM exc', (e as Error).message) }
  }
  return sent
}

Deno.serve(async (req) => {
  let payload: any
  try { payload = await req.json() } catch { return new Response(JSON.stringify({ error: 'bad json' }), { status: 200 }) }
  const record = payload.record || {}
  const oldRecord = payload.old_record || {}
  const billNo = record.bill_no || oldRecord.bill_no || 'جديد'
  const region = record.cust_region || ''
  const newDriver = record.driver_id || null
  const oldDriver = oldRecord.driver_id || null
  let sent = 0
  if (newDriver && newDriver !== oldDriver)
    sent += await sendToDriver(newDriver, '📦 طلب جديد وصلك!', `طلب #${billNo}${region ? ' - ' + region : ''}`)
  if (oldDriver && oldDriver !== newDriver)
    sent += await sendToDriver(oldDriver, '❌ تم سحب طلب', `تم سحب الطلب #${billNo} منك`)
  return new Response(JSON.stringify({ sent }), { status: 200, headers: { 'Content-Type': 'application/json' } })
})
