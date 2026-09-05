import { createClient } from 'npm:@supabase/supabase-js@2'
import bcrypt from 'npm:bcryptjs@2.4.3'

/* ═══════════════════════════════════════════════════════════════════
   تغيير كلمة سر الطيار — من التطبيق
   ═══════════════════════════════════════════════════════════════════
   ⚠️ الحراسة الخارجية ضعيفة (بتفحص إن المُنادي يقرا drivers، مش دوره)،
      **بس** الحارس الحقيقي هنا هو فحص كلمة السر القديمة بـbcrypt —
      يعني مايقدرش حد يغيّر باسورد طيار تاني من غير ما يعرف باسورده.
      لو الفحص ده اتشال يوم، الدالة تبقى ثغرة خطيرة.
   ═══════════════════════════════════════════════════════════════════ */

const URL = Deno.env.get('SUPABASE_URL')!
const SERVICE = Deno.env.get('SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!
const admin = createClient(URL, SERVICE)

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
function json(b: unknown) {
  return new Response(JSON.stringify(b), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ ok: false, error: 'غير مصرّح' })
  const userClient = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } })
  const { count, error: authErr } = await userClient.from('drivers').select('id', { count: 'exact', head: true })
  if (authErr || count === null || count === 0) return json({ ok: false, error: 'جلسة غير صالحة، سجّل الدخول من جديد' })

  let b: any
  try { b = await req.json() } catch { return json({ ok: false, error: 'بيانات غير صحيحة' }) }
  const driverId = b.driver_id
  const oldPw = (b.old_password ?? '').trim()
  const newPw = (b.new_password ?? '').trim()
  if (!driverId || !oldPw || !newPw) return json({ ok: false, error: 'املأ كل الحقول' })
  if (newPw.length < 4) return json({ ok: false, error: 'كلمة المرور الجديدة قصيرة (4 أحرف على الأقل)' })

  const { data: drv } = await admin.from('drivers').select('branch_user_id').eq('id', driverId).maybeSingle()
  const buId = drv?.branch_user_id
  if (!buId) return json({ ok: false, error: 'لا يوجد حساب دخول لهذا الطيار' })

  const { data: bu } = await admin.from('branch_users').select('id,password_hash').eq('id', buId).maybeSingle()
  if (!bu) return json({ ok: false, error: 'الحساب غير موجود' })

  // ⚠️ ده الحارس الحقيقي — ماتشيلوش
  let matches = false
  try { matches = bcrypt.compareSync(oldPw, bu.password_hash) } catch (_) { matches = false }
  if (!matches) return json({ ok: false, error: 'كلمة المرور الحالية غير صحيحة' })

  const hash = bcrypt.hashSync(newPw, 8)
  const { error: upErr } = await admin.from('branch_users').update({ password_hash: hash }).eq('id', buId)
  if (upErr) return json({ ok: false, error: 'تعذّر التحديث: ' + upErr.message })
  return json({ ok: true })
})
