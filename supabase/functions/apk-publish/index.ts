import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/* ═══════════════════════════════════════════════════════════════════
   نشر إصدار جديد من تطبيق الطيارين
   ═══════════════════════════════════════════════════════════════════
   ⚠️ الدالة دي كانت بتستعمل **نفس سر تطبيق الطيارين**، والسر ده منشور
      على GitHub في ريبو عام (جوّه الـworkflow وجوّه lib/config.dart).
      يعني أي حد كان يقدر **يستبدل الـAPK اللي بينزل على تليفونات
      الطيارين** — هجوم سلسلة توريد مكتمل.

   دلوقتي ليها سر **مستقل** (apk_publish_secret في vault)، ومابتقبلش
   سر التطبيق خالص — مفيش قبول انتقالي هنا عن قصد: سر منشور مايصحّش
   يفضل شغّال ولو دقيقة.

   الـworkflow بتاع البناء بياخد السر من أسرار الريبو:
     Settings → Secrets and variables → Actions → APK_PUBLISH_SECRET

   ⚠️ سر فاضي = رفض، مش سماح للكل.
   ═══════════════════════════════════════════════════════════════════ */

const SB_URL = Deno.env.get("SUPABASE_URL");
const SRK = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const BUCKET = "driver-apk";
const PATH = "phalix-driver.apk";

let _sec: { v: string; exp: number } | null = null;
async function publishSecret(): Promise<string> {
  const now = Date.now();
  if (_sec && _sec.exp > now) return _sec.v;
  const r = await fetch(`${SB_URL}/rest/v1/rpc/vault_secret`, {
    method: "POST",
    headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_name: "apk_publish_secret" }),
  });
  if (!r.ok) return "";
  const v = await r.json();
  const s = typeof v === "string" ? v : "";
  if (s) _sec = { v: s, exp: now + 60_000 };
  return s;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    const secret = await publishSecret();
    if (!secret || body.secret !== secret) return json({ ok: false, error: "unauthorized" }, 401);

    if (body.action === "sign") {
      // امسح القديم عشان الرفع الجديد ينجح دايمًا
      await fetch(`${SB_URL}/storage/v1/object/${BUCKET}/${PATH}`, {
        method: "DELETE",
        headers: { apikey: SRK, Authorization: `Bearer ${SRK}` },
      }).catch(() => {});
      const r = await fetch(`${SB_URL}/storage/v1/object/upload/sign/${BUCKET}/${PATH}`, {
        method: "POST",
        headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      const j = await r.json();
      if (!r.ok) return json({ ok: false, error: j }, 500);
      return json({ ok: true, full_url: `${SB_URL}/storage/v1${j.url}` });
    }

    if (body.action === "publish") {
      const vc = parseInt(`${body.version_code}`);
      if (!vc) return json({ ok: false, error: "no version_code" }, 400);
      // الرابط الافتراضي = تخزين Supabase؛ لكن لو الـworkflow بعت apk_url صريح
      // (مثلاً GitHub Releases) نستخدمه بدله لأنه أضمن للتنزيل على الشبكات الضعيفة
      const custom = typeof body.apk_url === "string" ? body.apk_url.trim() : "";
      const apkUrl = custom.length > 0
        ? custom
        : `${SB_URL}/storage/v1/object/public/${BUCKET}/${PATH}?download=${PATH}`;
      const r = await fetch(`${SB_URL}/rest/v1/driver_app_version?id=eq.1`, {
        method: "PATCH",
        headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json", Prefer: "return=minimal" },
        body: JSON.stringify({
          version_code: vc,
          version_name: body.version_name ?? null,
          apk_url: apkUrl,
          force_update: body.force === true,
          notes: body.notes ?? null,
          updated_at: new Date().toISOString(),
        }),
      });
      if (!r.ok) return json({ ok: false, error: await r.text() }, 500);
      return json({ ok: true, version_code: vc, apk_url: apkUrl });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
