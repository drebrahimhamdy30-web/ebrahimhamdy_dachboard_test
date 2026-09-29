import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   سحب كتالوج «ابن سينا فارما» → store_item_prices
   ═══════════════════════════════════════════════════════════════════
   نفس فكرة pharma_sync بالظبط: بوابة العملاء بتاعتهم
   (customerportal.ibnsina-pharma.com) واجهة Angular بتكلّم API عادي،
   فإحنا بنكلّم نفس الـAPI مباشرةً — من غير ما نلمس تطبيق الموبايل.

   الدخول: POST /Identity/v1.0/portal/Identity/Login {username, password}
           → data.token (Bearer) + refreshToken
   الأسعار: GET /product/v1/portal/search-products
           price = سعر الجمهور · pharmacyPrice = سعر الصيدلية بعد الخصم
           itemCode = كود الصنف عندهم (= supplier_code عندنا)

   ⚠️ الحساب لكل فرع منفصل — السر اسمه IBNSINA_AUTH_<الفرع>
      (مثال: IBNSINA_AUTH_mamora). بنبعت {account:"mamora"} نختار بيه.
   ⚠️ بتضرب API مورّد خارجي — ماتشغّلهاش من التست والسحابة مع بعض.
   ═══════════════════════════════════════════════════════════════════ */

const API = "https://portalgateway.ibnsina-pharma.com/api";
const LOGIN_URL = `${API}/Identity/v1.0/portal/Identity/Login`;
const PRODUCTS_URL = `${API}/product/v1/portal/search-products`;
const CUSTOMER_ITEMS_URL = `${API}/product/v1/portal/customerItems`;
const DEF_ACCOUNT = "mamora";

/* البوابة بتاعتهم ورا Cloudflare — النداء الجاف من سيرفر بيترد عليه
   403 بصفحة HTML. لازم نبعت نفس ترويسات المتصفح اللي البوابة نفسها
   بتبعتها (Origin/Referer/User-Agent)، وإلا مفيش رد أصلاً. */
const BROWSER = {
  "Accept": "application/json, text/plain, */*",
  "Accept-Language": "ar",
  "Origin": "https://customerportal.ibnsina-pharma.com",
  "Referer": "https://customerportal.ibnsina-pharma.com/",
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-sync-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
function jsonRes(b: unknown, s = 200) {
  return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
}
function claimFromJwt(a: string): any {
  try { const t = a.replace(/^Bearer\s+/i, ""); return JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); } catch { return null; }
}
const ADMIN_ROLES = ["admin", "manager", "inventory", "pharmacist"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const hdrKey = req.headers.get("x-sync-key") || "";
  const claims = claimFromJwt(req.headers.get("Authorization") || "");
  const isAdmin = !!claims && ADMIN_ROLES.includes(String(claims?.user_role ?? claims?.app_metadata?.user_role ?? claims?.app_role ?? ""));

  let opt: any = {}; try { opt = await req.json(); } catch { /* */ }
  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // نفس مفتاح الخزنة بتاع فارما — الكرون بيقراه من vault ويبعته
  let isCron = false;
  if (!isAdmin && hdrKey) {
    try { const { data } = await supa.rpc("is_pharma_sync_key", { p_key: hdrKey }); isCron = data === true; } catch { /* */ }
  }
  if (!isCron && !isAdmin) return jsonRes({ ok: false, error: "unauthorized" }, 403);

  // ── بيانات الدخول من سر الفرع ─────────────────────────────────
  const account = String(opt.account || DEF_ACCOUNT).replace(/[^A-Za-z0-9_]/g, "");
  const raw = Deno.env.get("IBNSINA_AUTH_" + account);
  if (!raw) return jsonRes({ ok: false, error: "secret_not_set", expected: "IBNSINA_AUTH_" + account }, 500);
  let cred: any; try { cred = JSON.parse(raw); } catch { return jsonRes({ ok: false, error: "bad_secret_json" }, 500); }
  if (!cred?.user || !cred?.pass) return jsonRes({ ok: false, error: "secret_missing_user_or_pass" }, 500);

  const t0 = Date.now();
  const lr = await fetch(LOGIN_URL, {
    method: "POST",
    headers: { ...BROWSER, "Content-Type": "application/json" },
    body: JSON.stringify({ username: String(cred.user), password: String(cred.pass) })
  });
  const lt = await lr.text();
  let lj: any = null; try { lj = JSON.parse(lt); } catch { /* */ }
  const token = lj?.data?.token;
  if (!lr.ok || !token) {
    // بنرجّع رسالة الخطأ بتاعتهم بس — من غير أي جزء من البيانات
    return jsonRes({
      ok: false, error: "login_failed", status: lr.status,
      detail: lj?.errorMessage || lj?.errorList?.[0] || lt.slice(0, 160)
    }, 502);
  }
  const H = { ...BROWSER, "Authorization": "Bearer " + token };

  /* ── وضع التجربة ──────────────────────────────────────────────
     بيجرّب 3 طرق لسحب الكتالوج ويقول كل واحدة رجّعت كام، عشان نعرف
     نمشي بأنهي طريقة قبل ما نكتب حاجة في القاعدة. مابيكتبش أي صف. */
  if (opt.probe === true) {
    const probe = async (label: string, url: string) => {
      try {
        const r = await fetch(url, { headers: H });
        const j = await r.json();
        const rows = j?.data?.searchResult || j?.data || [];
        const n = Array.isArray(rows) ? rows.length : 0;
        return {
          label, status: r.status, count: n,
          total: j?.data?.totalCount ?? null, hasNext: j?.data?.hasNextPage ?? null,
          sample: (Array.isArray(rows) ? rows : []).slice(0, 2).map((x: any) => ({
            itemCode: x.itemCode, nameAr: x.nameAr, name: x.name,
            price: x.price, pharmacyPrice: x.pharmacyPrice,
            expire: [x.expireLastMonth, x.expireLastYear].filter(Boolean).join("/") || null
          }))
        };
      } catch (e) { return { label, error: String(e).slice(0, 120) }; }
    };
    return jsonRes({
      ok: true, mode: "probe", account,
      pharmacy: lj?.data?.pharmacyName ?? null,
      login_seconds: Math.round((Date.now() - t0) / 100) / 10,
      tries: [
        await probe("no_params", PRODUCTS_URL),
        await probe("page_1_x100", `${PRODUCTS_URL}?PageIndex=1&PageSize=100`),
        await probe("page_1_x500", `${PRODUCTS_URL}?PageIndex=1&PageSize=500`),
        await probe("name_search", `${PRODUCTS_URL}?Name=${encodeURIComponent("بنادول")}&SearchType=0&PageIndex=1&PageSize=100`),
        await probe("customer_items", CUSTOMER_ITEMS_URL)
      ]
    });
  }

  return jsonRes({ ok: false, error: "no_mode", hint: "ابعت {probe:true} لحد ما نثبّت طريقة السحب" }, 400);
});
