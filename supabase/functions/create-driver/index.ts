import { createClient } from 'npm:@supabase/supabase-js@2'
import bcrypt from 'npm:bcryptjs@2.4.3'

/* ═══════════════════════════════════════════════════════════════════
   إنشاء طيار جديد — بيعمل حساب دخول (branch_users) + سجل طيار (drivers)
   ═══════════════════════════════════════════════════════════════════
   ⚠️ **الحراسة هنا ضعيفة:** بتتأكد إن المُنادي يقدر يقرا جدول drivers
      وبس. ده فحص **صلاحية قراءة** مش فحص **دور** — يعني أي مستخدم
      مسجّل دخول (حتى طيار عادي) يعدّي ويقدر ينشئ حسابات.
      المفروض تتحوّل لـ require_app_role(['admin','manager']) —
      ⚠️ بس بعد التأكد إن شاشة إدارة الطيارين بتبعت توكن أدمن فعلًا.

   ⚠️ لو إنشاء سجل الطيار فشل، بيمسح حساب الدخول اللي اتعمل — عشان
      مايفضلش حساب يتيم بلا طيار.
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

  // ===== التحقق من أن المُنادي مسجّل دخول (توكن صالح) =====
  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ ok: false, error: 'غير مصرّح' })
  const userClient = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } })
  const { count, error: authErr } = await userClient
    .from('drivers').select('id', { count: 'exact', head: true })
  if (authErr || count === null) return json({ ok: false, error: 'جلسة غير صالحة، سجّل الدخول من جديد' })

  // ===== قراءة البيانات =====
  let b: any
  try { b = await req.json() } catch { return json({ ok: false, error: 'بيانات غير صحيحة' }) }
  const full_name = (b.full_name ?? '').trim()
  const username = (b.username ?? '').trim()
  const password = (b.password ?? '').trim()
  const branch_id = b.branch_id ?? null
  if (!full_name || !username || !password || !branch_id)
    return json({ ok: false, error: 'الاسم واسم المستخدم وكلمة المرور والفرع مطلوبة' })

  const { data: br } = await admin.from('branches').select('name').eq('id', branch_id).single()
  const branchName = br?.name ?? null

  const { data: exists } = await admin.from('branch_users').select('id').eq('username', username).maybeSingle()
  if (exists) return json({ ok: false, error: 'اسم المستخدم مستخدم بالفعل' })

  const hash = bcrypt.hashSync(password, 8)

  const { data: bu, error: buErr } = await admin.from('branch_users').insert({
    username, password_hash: hash, full_name, branch: branchName,
    role: 'driver', is_active: b.is_active ?? true, mobile: b.phone ?? null,
  }).select('id').single()
  if (buErr) return json({ ok: false, error: 'خطأ في إنشاء الحساب: ' + buErr.message })

  const { data: drv, error: drvErr } = await admin.from('drivers').insert({
    full_name, phone: b.phone ?? null, national_id: b.national_id ?? null,
    branch_id, branch: branchName, vehicle_type: b.vehicle_type ?? null,
    vehicle_plate: b.vehicle_plate ?? null, is_active: b.is_active ?? true,
    is_online: b.is_online ?? false, has_vehicle_license: !!b.has_vehicle_license,
    has_drive_license: !!b.has_drive_license, covered_types: b.covered_types ?? [],
    branch_user_id: bu.id,
  }).select('id').single()
  if (drvErr) {
    // تراجع: مانسيبش حساب دخول يتيم بلا سجل طيار
    await admin.from('branch_users').delete().eq('id', bu.id)
    return json({ ok: false, error: 'خطأ في إنشاء السائق: ' + drvErr.message })
  }

  return json({ ok: true, driver_id: drv.id, branch_user_id: bu.id })
})
