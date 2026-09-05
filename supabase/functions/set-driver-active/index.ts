import { createClient } from 'npm:@supabase/supabase-js@2'

/* ═══════════════════════════════════════════════════════════════════
   تفعيل/تعطيل حساب دخول الطيار
   ═══════════════════════════════════════════════════════════════════
   ⚠️ نفس ملاحظة create-driver: الحراسة بتفحص إن المُنادي **يقدر يقرا**
      جدول drivers — ده فحص صلاحية قراءة مش فحص دور. أي مستخدم مسجّل
      دخول يعدّي، ويقدر يعطّل حساب أي طيار برقمه.
      المفروض require_app_role(['admin','manager']) بعد التأكد إن
      الشاشة بتبعت توكن أدمن.
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
function json(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ ok: false, error: 'غير مصرّح' })
  const userClient = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } })
  const { count, error: authErr } = await userClient.from('drivers').select('id', { count: 'exact', head: true })
  if (authErr || count === null) return json({ ok: false, error: 'جلسة غير صالحة' })

  let b: any
  try { b = await req.json() } catch { return json({ ok: false, error: 'بيانات غير صحيحة' }) }
  const branchUserId = b.branch_user_id
  const isActive = !!b.is_active
  if (!branchUserId) return json({ ok: true, note: 'no branch_user_id' })
  const { error } = await admin.from('branch_users').update({ is_active: isActive }).eq('id', branchUserId)
  if (error) return json({ ok: false, error: error.message })
  return json({ ok: true })
})
