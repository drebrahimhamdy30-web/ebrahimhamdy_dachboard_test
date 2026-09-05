import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/* ═══════════════════════════════════════════════════════════════════
   وسيط استعلام نظام eplus — شاشة «الربط بالمصادر» بتستعمله
   ═══════════════════════════════════════════════════════════════════
   ⚠️ الدالة دي **بتضرب نظام eplus الحقيقي**. على سيرفر التجربة خليها
      محدودة الاستعمال — كل نداء بيروح لنفس النظام اللي الإنتاج شغّال
      عليه، والضغط المضاعف بيأثر على الشغل الفعلي.

   ⚠️ الحراسة هنا **بالدور من التوكن** (`user_role`/`app_role`) —
      أقوى من دوال الطيارين اللي بتفحص صلاحية قراءة بس. وverify_jwt=true
      كمان، فمفيش نداء بلا توكن أصلًا.

   ⚠️ بيانات الدخول من متغيّرات البيئة (مافيش سر في الملف):
      EPLUS_BRANCHES = {"اسم الفرع": {"base":"https://...","basic":"user:pass"}}
      أو EPLUS_BASE + EPLUS_BASIC لفرع واحد.
   ═══════════════════════════════════════════════════════════════════ */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const ALLOWED_ROLES = ["admin", "manager", "inventory", "pharmacist"];

function jsonRes(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function claimFromJwt(auth: string): any {
  try {
    const tok = auth.replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  } catch { return null; }
}
function resolveBranch(branch: string): { base?: string; basic?: string; error?: string; branches?: string[] } {
  const raw = Deno.env.get("EPLUS_BRANCHES");
  if (raw) {
    let map: Record<string, { base?: string; basic?: string }> = {};
    try { map = JSON.parse(raw); } catch { return { error: "bad_EPLUS_BRANCHES_json" }; }
    const b = map[branch];
    if (!b) return { error: "branch_not_configured", branches: Object.keys(map) };
    return { base: b.base, basic: b.basic };
  }
  return { base: Deno.env.get("EPLUS_BASE"), basic: Deno.env.get("EPLUS_BASIC") };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const claims = claimFromJwt(req.headers.get("Authorization") || "");
  const role = String(claims?.user_role ?? claims?.app_role ?? "");
  if (!claims || !ALLOWED_ROLES.includes(role)) {
    return jsonRes({ ok: false, error: "unauthorized", hint: "يتطلب تسجيل دخول موظف" }, 403);
  }

  let inp: any = {};
  try { inp = await req.json(); } catch { /* */ }
  const branch = String(inp.branch || "");
  const resolved = resolveBranch(branch);
  if (resolved.error === "branch_not_configured")
    return jsonRes({ ok: false, error: "branch_not_configured", branch, configured: resolved.branches, hint: "أضف الفرع لـ EPLUS_BRANCHES" }, 400);
  if (resolved.error) return jsonRes({ ok: false, error: resolved.error }, 500);
  const base = resolved.base, basic = resolved.basic;
  if (!base || !basic) return jsonRes({ ok: false, error: "secret_not_set", hint: "اضبط EPLUS_BRANCHES" }, 500);
  const authHeader = "Basic " + (String(basic).includes(":") ? btoa(basic) : basic);

  const path = String(inp.path || "");
  const method = String(inp.method || "GET").toUpperCase();
  const preview = inp.preview !== false;
  const previewN = Math.min(Number(inp.previewN) || 50, 500);
  if (!path.startsWith("/")) return jsonRes({ ok: false, error: "bad_path", hint: "المسار يبدأ بـ/" }, 400);

  const usp = new URLSearchParams();
  (Array.isArray(inp.params) ? inp.params : []).forEach((p: any) => {
    if (p && p.enabled !== false && p.key) usp.append(String(p.key), String(p.value ?? ""));
  });
  const qs = usp.toString();
  const url = base.replace(/\/$/, "") + path + (method === "GET" && qs ? "?" + qs : "");

  const opts: RequestInit = { method, headers: { "Authorization": authHeader, "Accept": "application/json" }, redirect: "follow" };
  if (method !== "GET") {
    (opts.headers as Record<string, string>)["Content-Type"] = "application/json";
    opts.body = inp.body || (qs ? JSON.stringify(Object.fromEntries(usp)) : "{}");
  }

  const t0 = Date.now();
  let r: Response; let text: string;
  try { r = await fetch(url, opts); text = await r.text(); }
  catch (e) { return jsonRes({ ok: false, error: "fetch_failed", detail: String((e as Error)?.message || e), url }, 502); }
  const ms = Date.now() - t0;

  // معاينة: مانرجّعش آلاف الصفوف للمتصفح — بنقص ونقول العدد الحقيقي
  let allRecords: number | null = null, dataLen: number | null = null, output = text;
  try {
    const j = JSON.parse(text);
    allRecords = (j.AllRecords ?? null) as number | null;
    if (Array.isArray(j.Data)) {
      dataLen = j.Data.length;
      if (preview) output = JSON.stringify({ ...j, Data: j.Data.slice(0, previewN) });
    } else if (text.length > 300000) output = text.slice(0, 300000) + "…";
  } catch { if (text.length > 300000) output = text.slice(0, 300000) + "…"; }

  return jsonRes({ ok: r.ok, status: r.status, url, branch, time_ms: ms, size_bytes: text.length, all_records: allRecords, returned: dataLen, preview, previewN, output });
});
