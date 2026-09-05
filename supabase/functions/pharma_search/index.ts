import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/* ═══════════════════════════════════════════════════════════════════
   بحث أدوية من موقع Pharma e-Market (SAP Commerce OCC)
   ═══════════════════════════════════════════════════════════════════
   السر PHARMA_MARKET_AUTH = {"user":"email","pass":"password",
                              "api":"https://api...ondemand.com","site":"pharma"}
   المصادقة: OAuth2 password grant. الأسعار بتظهر بعد دخول العميل بس.

   ⚠️ OAUTH_CLIENT="mobile_android" و OAUTH_SECRET="secret" **مش أسرار
      Phalix** — دي قيم SAP Commerce/Hybris الافتراضية المعروفة والموثّقة
      علنًا. فاحص الأسرار فلّجها مرة كإيجابية كاذبة. بيانات الدخول
      الحقيقية في PHARMA_MARKET_AUTH وهو متغيّر بيئة.

   ⚠️ الدالة بتضرب **API خارجي لمورّد**. على سيرفر التجربة استعملها
      بحساب — الضغط المضاعف بيتحسب على نفس الحساب بتاع الإنتاج.
   ═══════════════════════════════════════════════════════════════════ */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const ALLOWED_ROLES = ["admin", "manager", "inventory", "pharmacist", "purchasing"];

const DEF_API = "https://api.c0umyt3cda-pharmaove1-p1-public.model-t.cc.commerce.ondemand.com";
const DEF_SITE = "pharma";
const OAUTH_CLIENT = "mobile_android";
const OAUTH_SECRET = "secret";

function jsonRes(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function claimFromJwt(auth: string): any {
  try { const tok = auth.replace(/^Bearer\s+/i, ""); return JSON.parse(atob(tok.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); } catch { return null; }
}
function stripTags(s: string): string { return String(s || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim(); }

type Creds = { user: string; pass: string; api: string; site: string };
function readCreds(): { creds?: Creds; error?: string } {
  const raw = Deno.env.get("PHARMA_MARKET_AUTH");
  if (!raw) return { error: "secret_not_set" };
  let o: any;
  try { o = JSON.parse(raw); } catch { return { error: "bad_secret_json" }; }
  if (!o.user || !o.pass) return { error: "secret_missing_user_pass" };
  return { creds: { user: String(o.user), pass: String(o.pass), api: String(o.api || DEF_API).replace(/\/$/, ""), site: String(o.site || DEF_SITE) } };
}

// تخزين التوكن مؤقتًا داخل نفس نسخة الدالة
let _tok: string | null = null;
let _tokExp = 0;
async function getToken(c: Creds): Promise<{ token?: string; error?: string; detail?: string }> {
  if (_tok && Date.now() < _tokExp) return { token: _tok };
  const body = new URLSearchParams({
    client_id: OAUTH_CLIENT, client_secret: OAUTH_SECRET,
    grant_type: "password", username: c.user, password: c.pass,
  });
  let r: Response, t: string;
  try {
    r = await fetch(c.api + "/authorizationserver/oauth/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
    });
    t = await r.text();
  } catch (e) { return { error: "oauth_fetch_failed", detail: String((e as Error)?.message || e) }; }
  if (!r.ok) return { error: "oauth_failed", detail: t.slice(0, 300) };
  let j: any; try { j = JSON.parse(t); } catch { return { error: "oauth_bad_json", detail: t.slice(0, 200) }; }
  _tok = j.access_token;
  _tokExp = Date.now() + Math.max(30, (Number(j.expires_in) || 300) - 60) * 1000;
  return { token: _tok };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const claims = claimFromJwt(req.headers.get("Authorization") || "");
  const role = String(claims?.user_role ?? claims?.app_role ?? "");
  if (!claims || !ALLOWED_ROLES.includes(role)) {
    return jsonRes({ ok: false, error: "unauthorized", hint: "يتطلب تسجيل دخول موظف" }, 403);
  }

  const { creds, error } = readCreds();
  if (error) return jsonRes({ ok: false, error, hint: "اضبط السر PHARMA_MARKET_AUTH في Edge Functions Secrets" }, error === "secret_not_set" ? 500 : 400);
  const c = creds!;

  let inp: any = {};
  try { inp = await req.json(); } catch { /* */ }
  const query = String(inp.query || "").trim();
  const page = Math.max(0, Number(inp.page) || 0);
  const pageSize = Math.min(Math.max(1, Number(inp.pageSize) || 20), 50);
  if (!query) return jsonRes({ ok: false, error: "empty_query", hint: "اكتب اسم صنف للبحث" }, 400);

  const tk = await getToken(c);
  if (tk.error) return jsonRes({ ok: false, ...tk }, 502);

  const fields = "products(code,name,price(FULL),stock(stockLevelStatus,stockLevel),manufacturer,images(DEFAULT)),pagination(DEFAULT),freeTextSearch";
  const url = `${c.api}/occ/v2/${encodeURIComponent(c.site)}/products/search`
    + `?query=${encodeURIComponent(query)}&currentPage=${page}&pageSize=${pageSize}`
    + `&fields=${encodeURIComponent(fields)}&lang=ar&curr=EGP`;

  let r: Response, t: string;
  try { r = await fetch(url, { headers: { "Authorization": "Bearer " + tk.token, "Accept": "application/json" } }); t = await r.text(); }
  catch (e) { return jsonRes({ ok: false, error: "search_fetch_failed", detail: String((e as Error)?.message || e) }, 502); }

  if (r.status === 401) { _tok = null; _tokExp = 0; return jsonRes({ ok: false, error: "token_rejected", hint: "تحقق من الإيميل/الباسورد في السر" }, 502); }
  let j: any; try { j = JSON.parse(t); } catch { return jsonRes({ ok: false, error: "search_bad_json", detail: t.slice(0, 300) }, 502); }

  const results = (Array.isArray(j.products) ? j.products : []).map((p: any) => {
    const pr = p.price || {}; const st = p.stock || {};
    return {
      code: p.code || null,
      name: stripTags(p.name),
      price: (typeof pr.value === "number") ? pr.value : (pr.value != null ? Number(pr.value) : null),
      price_text: pr.formattedValue || null,
      currency: pr.currencyIso || null,
      stock: st.stockLevelStatus || null,
      stock_qty: (st.stockLevel != null ? Number(st.stockLevel) : null),
      manufacturer: p.manufacturer || null,
    };
  });
  const pg = j.pagination || {};
  return jsonRes({
    ok: true, query,
    page: pg.currentPage ?? page, pageSize: pg.pageSize ?? pageSize,
    total: pg.totalResults ?? results.length, total_pages: pg.totalPages ?? null,
    count: results.length, results,
  });
});
