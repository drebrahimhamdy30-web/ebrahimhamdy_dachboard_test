import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   سحب كتالوج فارما اوفر سيز → store_item_prices
   ═══════════════════════════════════════════════════════════════════
   مقارنة أسعار وخصومات بس — التوفر يتأكد وقت الطلب (الموقع مابيعرضش
   مخزون حقيقي للوصول اللي عندنا).
   بتشتغل على دفعات: {from_page, pages}، والإنهاء: {finalize:true, started}.

   ⚠️ **بتضرب API مورّد خارجي بكثافة** — عشرات النداءات المتوازية لكل
      تشغيلة. على سيرفر التجربة **ماتشغّلش الـcron بتاعها**: هتبقى
      ضغط مضاعف على نفس حساب المورّد اللي الإنتاج شغّال عليه.

   ⚠️ client_secret="secret" و client_id="mobile_android" **مش أسرار
      Phalix** — قيم SAP Commerce الافتراضية المعروفة. الحقيقي في
      PHARMA_MARKET_AUTH (متغيّر بيئة).

   ⚠️ المصادقة بطريقتين: مفتاح cron (x-sync-key = SYNC_KEY) أو توكن
      موظف بدور مسموح. سر فاضي = رفض (`!!SYNC_KEY` في الشرط).
   ═══════════════════════════════════════════════════════════════════ */

const STORE = "فارما اوفر سيز";
const DEF_API = "https://api.c0umyt3cda-pharmaove1-p1-public.model-t.cc.commerce.ondemand.com";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-sync-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
function jsonRes(b: unknown, s = 200) { return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } }); }
function claimFromJwt(a: string): any { try { const t = a.replace(/^Bearer\s+/i, ""); return JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); } catch { return null; } }
const ADMIN_ROLES = ["admin", "manager", "inventory", "pharmacist"];
function stripTags(s: string) { return String(s || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim(); }
function round2(n: number) { return Math.round(n * 100) / 100; }
const clampD = (n: number) => Math.min(Math.max(n, 0), 100);

// تنفيذ متوازٍ بسقف — من غيره آلاف النداءات تنطلق مرة واحدة ويترفض الاتصال
async function pool<T, R>(items: T[], size: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length); let i = 0;
  async function w() { while (i < items.length) { const k = i++; out[k] = await fn(items[k]); } }
  await Promise.all(Array.from({ length: Math.min(size, items.length) }, w));
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const SYNC_KEY = Deno.env.get("SYNC_KEY");
  const hdrKey = req.headers.get("x-sync-key") || "";
  let isCron = !!SYNC_KEY && hdrKey === SYNC_KEY;
  const claims = claimFromJwt(req.headers.get("Authorization") || "");
  const isAdmin = !!claims && ADMIN_ROLES.includes(String(claims?.user_role ?? claims?.app_metadata?.user_role ?? claims?.app_role ?? ""));

  let opt: any = {}; try { opt = await req.json(); } catch { /* */ }
  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  /* مفتاح الكرون محفوظ في vault مش في متغيّرات البيئة — الكرون بيقراه
     من هناك ويبعته، وإحنا بنتحقق منه بدالة. كده مفيش خطوة يدوية في
     لوحة التحكم ولا مفتاح بيتنقل بره القاعدة. */
  if (!isCron && !isAdmin && hdrKey) {
    try {
      const { data } = await supa.rpc("is_pharma_sync_key", { p_key: hdrKey });
      isCron = data === true;
    } catch { /* */ }
  }
  if (!isCron && !isAdmin) return jsonRes({ ok: false, error: "unauthorized" }, 403);

  // الإنهاء: أي صنف مااتحدّثش في الجولة دي = مش متاح
  if (opt.finalize === true) {
    const started = String(opt.started || "");
    if (!started) return jsonRes({ ok: false, error: "missing_started" }, 400);
    const { data, error } = await supa.rpc("pharma_prices_finalize", { p_before: started });
    if (error) return jsonRes({ ok: false, error: error.message }, 500);
    return jsonRes({ ok: true, mode: "finalize", marked_unavailable: Number(data) || 0 });
  }

  const rawCreds = Deno.env.get("PHARMA_MARKET_AUTH");
  if (!rawCreds) return jsonRes({ ok: false, error: "secret_not_set" }, 500);
  let o: any; try { o = JSON.parse(rawCreds); } catch { return jsonRes({ ok: false, error: "bad_secret_json" }, 500); }
  const api = String(o.api || DEF_API).replace(/\/$/, ""); const site = String(o.site || "pharma");
  let fromPage = Math.max(0, Number(opt.from_page) || 0);
  let pagesN = Math.min(Math.max(Number(opt.pages) || 40, 1), 80);
  const t0 = Date.now();

  /* التشغيل المجدول: الحالة في الجدول هي اللي بتقول نبدأ من فين، وكل
     تشغيلة بتسجّل نفسها في pharma_sync_log وتقدّم المؤشّر — فأي فشل
     بيبان في السجل وفي عدّاد الفشل المتتالي بدل ما يعدّي ساكت. */
  let sched: any = null;
  if (opt.scheduled === true) {
    const { data: st, error: stErr } = await supa.from("pharma_sync_state").select("*").eq("id", 1).single();
    if (stErr || !st) return jsonRes({ ok: false, error: "state_read_failed", detail: stErr?.message }, 500);
    if (!st.enabled) { await supa.from("pharma_sync_state").update({ running_since: null }).eq("id", 1); return jsonRes({ ok: true, mode: "scheduled", skipped: "disabled" }); }
    sched = st;
    fromPage = Math.max(0, Number(st.next_page) || 0);
    pagesN = Math.min(Math.max(Number(st.pages_per_run) || 10, 1), 80);
  }
  const cSearch = Math.min(Math.max(Number(opt.concurrency) || 8, 1), 12);
  const cDetail = Math.min(Math.max(Number(opt.detail_concurrency) || 15, 1), 24);
  const startedIso = new Date().toISOString();

  const tr = await fetch(api + "/authorizationserver/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: "mobile_android", client_secret: "secret", grant_type: "password", username: String(o.user), password: String(o.pass) })
  });
  const tt = await tr.text();
  if (!tr.ok) {
    if (sched) {
      await supa.from("pharma_sync_log").insert({ from_page: fromPage, ok: false, error: "oauth_failed: " + tt.slice(0, 160) });
      await supa.from("pharma_sync_state").update({ running_since: null, last_run_at: new Date().toISOString(), last_ok: false,
        last_error: "فشل الدخول على فارما", consecutive_failures: (Number(sched.consecutive_failures) || 0) + 1 }).eq("id", 1);
    }
    return jsonRes({ ok: false, error: "oauth_failed", detail: tt.slice(0, 200) }, 502);
  }
  const token = JSON.parse(tt).access_token;
  const H = { "Authorization": "Bearer " + token, "Accept": "application/json", "Accept-Language": "ar" };
  const fields = "products(code,name,price(value),publicPrice(value),stock(stockLevelStatus)),pagination(totalPages,totalResults)";
  const pageUrl = (p: number) => `${api}/occ/v2/${site}/products/search?query=:relevance&currentPage=${p}&pageSize=100&lang=ar&fields=${encodeURIComponent(fields)}`;

  type Item = { code: string; name: string; pub: number | null; net: number | null };
  function itemsOf(prods: any[]): Item[] {
    const out: Item[] = [];
    for (const p of (prods || [])) {
      if (String(p.stock?.stockLevelStatus || "").toLowerCase() !== "instock") continue;
      const name = stripTags(p.name); if (!name || !p.code) continue;
      out.push({ code: p.code, name, pub: p.publicPrice?.value ?? null, net: p.price?.value ?? null });
    }
    return out;
  }

  const fr = await fetch(pageUrl(fromPage), { headers: H });
  if (!fr.ok) {
    if (sched) {
      await supa.from("pharma_sync_log").insert({ from_page: fromPage, ok: false, error: "search_failed status " + fr.status });
      await supa.from("pharma_sync_state").update({ running_since: null, last_run_at: new Date().toISOString(), last_ok: false,
        last_error: "فشل البحث (status " + fr.status + ")", consecutive_failures: (Number(sched.consecutive_failures) || 0) + 1 }).eq("id", 1);
    }
    return jsonRes({ ok: false, error: "search_failed", status: fr.status }, 502);
  }
  const fj = await fr.json();
  const totalPages = Number(fj.pagination?.totalPages) || 1;
  const totalResults = Number(fj.pagination?.totalResults) || 0;
  const lastPage = Math.min(fromPage + pagesN - 1, totalPages - 1);

  const items: Item[] = itemsOf(fj.products);
  let failedPages = 0;
  const restPages = [];
  for (let p = fromPage + 1; p <= lastPage; p++) restPages.push(p);
  const pageArrs = await pool(restPages, cSearch, async (pg) => {
    for (let a = 0; a < 2; a++) { try { const r = await fetch(pageUrl(pg), { headers: H }); if (r.ok) return itemsOf((await r.json()).products); } catch { /* */ } }
    failedPages++; return [] as Item[];
  });
  for (const arr of pageArrs) for (const it of arr) items.push(it);

  /* وضع «الأكواد بس»: بيقف عند صفحات البحث ومابيعملش نداء تفاصيل لكل
     صنف (اللي هو 19 ألف نداء في الجولة الكاملة). الكود بيجي في صفحة
     البحث أصلًا، فالتمريرة دي ~221 نداء بس وحملها تافه. مابيلمسش
     السعر/الخصم/التوفر — تحديث عمود supplier_code وخلاص. */
  if (opt.codes_only === true) {
    const crows = items.map((it) => ({ item_name: it.name, supplier_code: it.code }));
    let matched = 0; let cErr: string | null = null;
    for (let i = 0; i < crows.length; i += 1000) {
      const { data, error } = await supa.rpc("pharma_codes_upsert", { p_rows: crows.slice(i, i + 1000) });
      if (error) { cErr = error.message; break; }
      matched += Number(data) || 0;
    }
    return jsonRes({ ok: !cErr, mode: "codes_only", from_page: fromPage, to_page: lastPage,
      total_pages: totalPages, catalog_total: totalResults, scanned: items.length,
      updated: matched, failed_pages: failedPages, up_error: cErr });
  }

  // الخصم المُعلَن للصيدليات — نداء تفصيلي لكل صنف
  const detUrl = (c: string) => `${api}/occ/v2/${site}/products/${c}?fields=pharmacyDiscount(value)`;
  let detailFails = 0;
  const rows = await pool(items, cDetail, async (it) => {
    let adv: number | null = null; let got = false;
    for (let a = 0; a < 2; a++) { try { const r = await fetch(detUrl(it.code), { headers: H }); if (r.ok) { const d = await r.json(); adv = d?.pharmacyDiscount?.value ?? null; got = true; break; } } catch { /* */ } }
    if (!got) detailFails++;
    let price: number | null, disc: number;
    if (adv != null) { price = (it.pub ?? it.net); disc = clampD(Number(adv)); }
    else if (it.pub != null && it.pub > 0 && it.net != null) { price = it.pub; disc = clampD(round2((1 - it.net / it.pub) * 100)); }
    else if (it.net != null) { price = it.net; disc = 0; }
    else return null;
    return { item_name: it.name, price, discount_perc: disc, available: true, supplier_code: it.code };
  });
  const all = rows.filter(Boolean) as any[];

  let upserted = 0; let upErr: string | null = null;
  for (let i = 0; i < all.length; i += 1000) {
    const chunk = all.slice(i, i + 1000);
    const { data, error } = await supa.rpc("pharma_prices_upsert", { p_rows: chunk });
    if (error) { upErr = error.message; break; }
    upserted += Number(data) || 0;
  }

  const secs = Math.round((Date.now() - t0) / 100) / 10;
  const okRun = !upErr && failedPages === 0;

  if (sched) {
    const cycleStart = fromPage === 0 ? new Date().toISOString() : (sched.cycle_started_at || new Date().toISOString());
    const finished = lastPage >= totalPages - 1;
    let finalized: number | null = null;

    // آخر دفعة في الدورة: أي صنف مااتشافش في الدورة دي = خرج من الكتالوج
    if (okRun && finished) {
      try {
        const { data } = await supa.rpc("pharma_prices_finalize", { p_before: cycleStart });
        finalized = Number(data) || 0;
      } catch { /* */ }
    }

    await supa.from("pharma_sync_log").insert({
      from_page: fromPage, to_page: lastPage, total_pages: totalPages,
      processed: all.length, upserted, codes: all.filter((x: any) => x.supplier_code).length,
      failed_pages: failedPages, detail_fails: detailFails,
      ok: okRun, error: upErr, seconds: secs
    });

    await supa.from("pharma_sync_state").update({
      running_since: null,
      last_run_at: new Date().toISOString(),
      last_ok: okRun,
      last_error: okRun ? null : (upErr || (failedPages ? failedPages + " صفحة فشلت" : "غير معروف")),
      consecutive_failures: okRun ? 0 : (Number(sched.consecutive_failures) || 0) + 1,
      total_pages: totalPages,
      cycle_started_at: cycleStart,
      // الدفعة الفاشلة بتتعاد في النبضة الجاية بدل ما نتخطاها
      next_page: okRun ? (finished ? 0 : lastPage + 1) : fromPage,
      cycle_no: (okRun && finished) ? (Number(sched.cycle_no) || 0) + 1 : sched.cycle_no
    }).eq("id", 1);

    return jsonRes({ ok: okRun, mode: "scheduled", from_page: fromPage, to_page: lastPage, total_pages: totalPages,
      processed: all.length, upserted, failed_pages: failedPages, detail_fails: detailFails,
      cycle_finished: finished, finalized, seconds: secs, up_error: upErr });
  }

  return jsonRes({ ok: !upErr, mode: "chunk", chunk_started: startedIso, from_page: fromPage, to_page: lastPage, total_pages: totalPages, catalog_total: totalResults, processed: all.length, failed_pages: failedPages, detail_fails: detailFails, upserted, seconds: secs, up_error: upErr });
});
