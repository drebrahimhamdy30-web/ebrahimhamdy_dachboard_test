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
  /* 6 بدل 15: النبضة بتعمل ~1000 نداء على صفحات المنتجات، والتوازي
     العالي كان بيرشّهم في 9 ثوانٍ (~110 نداء/ثانية على سيرفرهم).
     بـ6 بتاخد ~25 ثانية — نفس العدد بس مفرود، ولسه جوّه حدود النبضة. */
  const cDetail = Math.min(Math.max(Number(opt.detail_concurrency) || 6, 1), 24);
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

  /* السعر الصح من صفحة المنتج مش من فهرس البحث ⚠️
     ────────────────────────────────────────────
     اتكشف 2026-09-29: فهرس البحث عندهم **بيقدم**. «ليمتلس فورتاليز»
     كان البحث بيقول publicPrice=57 وصفحة المنتج بتقول 70 (وموقعهم
     نفسه بيعرض 70).
     الخصم نفسه (`pharmacyDiscount`) **مابيتغيّرش** — ده الخصم
     التعاقدي الحقيقي بقرار المالك. اللي اتصلح هو مصدر **السعر** بس.
     وإحنا أصلًا بنضرب صفحة المنتج لكل صنف، فالإصلاح مجاني — مجرد
     طلب حقلين زيادة في نفس النداء. */
  const detUrl = (c: string) => `${api}/occ/v2/${site}/products/${c}?fields=pharmacyDiscount(value),price(value),publicPrice(value)&lang=ar`;

  /* تطبيع الاسم للمطابقة التامة بس.
     مقصود إنه **مايسامحش في الأرقام**: «20 قرص» و«30 قرص» يفضلوا
     مختلفين، لأن كود غلط = تطلب عبوة تانية. بنوحّد بس اللي مابيغيّرش
     الصنف: التشكيل، أشكال الألف والياء والتاء المربوطة، والمسافات
     وعلامات الترقيم. */
  // بالـ\u مقصود: التشكيل حروف غير مرئية، وكتابتها حرفيًا في الملف
  // بتتبوّظ بسهولة مع أي محرر أو نقل بين الريبوهين.
  const norm = (s: string) => String(s || "")
    .replace(/[ً-ْٰـ]/g, "")                    // تشكيل وتطويل
    .replace(/[أإآٱ]/g, "ا")               // أ إ آ ٱ → ا
    .replace(/ى/g, "ي").replace(/ة/g, "ه")      // ى→ي · ة→ه
    .replace(/ؤ/g, "و").replace(/ئ/g, "ي")      // ؤ→و · ئ→ي
    .toLowerCase()
    .replace(/[^0-9a-zء-ي]/g, "");                        // شيل أي حاجة مش حرف ولا رقم

  // نفس حساب السعر/الخصم في كل الأوضاع — لازم يفضل واحد
  function priceOf(adv: number | null, pub: number | null, net: number | null) {
    if (adv != null) { const p = (pub ?? net); return p == null ? null : { price: p, disc: clampD(Number(adv)) }; }
    if (pub != null && pub > 0 && net != null) return { price: pub, disc: clampD(round2((1 - net / pub) * 100)) };
    if (net != null) return { price: net, disc: 0 };
    return null;
  }

  /* ── وضع الفحص ────────────────────────────────────────────────
     {lookup:"جزء من الاسم"} بيدوّر على صنف ويرجّع الحقول الخام زي ما
     فارما بعتتها بالظبط، من غير أي حساب ولا كتابة. ده اللي بيفرّق بين
     «المزامنة بايظة» و«فارما نفسها عندها السعر القديم». */
  if (typeof opt.lookup === "string" && opt.lookup.trim()) {
    const q = opt.lookup.trim();
    const lu = `${api}/occ/v2/${site}/products/search?query=${encodeURIComponent(q)}&currentPage=0&pageSize=10&lang=ar`
      + `&fields=${encodeURIComponent("products(code,name,price(value),publicPrice(value),stock(stockLevelStatus)),pagination(totalResults)")}`;
    const lr2 = await fetch(lu, { headers: H });
    if (!lr2.ok) return jsonRes({ ok: false, error: "lookup_failed", status: lr2.status }, 502);
    const lj2 = await lr2.json();
    const found = [];
    for (const p of (lj2.products || []).slice(0, 6)) {
      let det: any = null;
      try {
        const dr = await fetch(`${api}/occ/v2/${site}/products/${p.code}?fields=FULL`, { headers: H });
        if (dr.ok) det = await dr.json();
      } catch { /* */ }
      found.push({
        code: p.code, name: stripTags(p.name),
        search_publicPrice: p.publicPrice?.value ?? null,   // ← ده اللي بنخزّنه حاليًا
        search_price: p.price?.value ?? null,
        detail_publicPrice: det?.publicPrice?.value ?? null, // ← الصفحة عندهم بتعرض ده
        detail_price: det?.price?.value ?? null,
        detail_discount: det?.pharmacyDiscount?.value ?? null,
        detail_tax: det?.taxValue ?? det?.tax?.value ?? det?.vat ?? null,
        stock: p.stock?.stockLevelStatus ?? null
      });
    }
    return jsonRes({ ok: true, mode: "lookup", query: q, total: lj2.pagination?.totalResults ?? null, found });
  }

  /* ── تحديث مستهدف بالكود ───────────────────────────────────────
     {refresh_codes:[...]} بياخد أكواد المورّد اللي عندنا ويجيب سعر
     وخصم كل واحد من صفحة المنتج، من غير أي مرور على صفحات البحث.
     ده اللي بيستعمله زر «حدّث أسعار دول» في قائمة فارما قبل الطلب:
     أصناف الطلبية عشرات مش آلاف، فبيخلص في ثواني بدل الجولة الكاملة.

     الكتابة **بالكود مش بالاسم** (`pharma_prices_refresh`): الاسم عند
     فارما بيختلف حرف عن اللي مخزّن عندنا، والـupsert بالاسم كان
     هيعمل صف جديد بدل ما يحدّث الموجود. ومابيعملش finalize — ده
     تحديث نقطة مش جولة، فغياب صنف عن القايمة مش معناه إنه خرج من
     الكتالوج. */
  if ((Array.isArray(opt.refresh_codes) && opt.refresh_codes.length) ||
      (Array.isArray(opt.fill_names) && opt.fill_names.length)) {
    const codes = [...new Set((opt.refresh_codes || []).map((c: any) => String(c || "").trim()).filter(Boolean))].slice(0, 900);

    /* الأصناف اللي مالهاش كود مورّد: ندوّر عليها بالاسم ونقبل **المطابقة
       التامة بعد التطبيع بس**. الاسم عندنا في الصفوف دي جاي من شيت
       مرفوع مش من كتالوجهم، فبيختلف — واللي مايطابقش بالظبط نسيبه فاضي
       ونعدّه، مانخمّنش. كود غلط أخطر من كود ناقص. */
    const nameList = [...new Set((opt.fill_names || []).map((s: any) => String(s || "").trim()).filter(Boolean))].slice(0, 300);
    let codesFilled = 0, codesUnmatched = 0; let cErr2: string | null = null;
    if (nameList.length) {
      const found = await pool(nameList, cDetail, async (nm) => {
        /* البحث **بأول كلمة** مش بالاسم الكامل: سيرفرهم بيرجّع 400 على
           الاسم الطويل (مجرَّب: «اتومافيوتكس شراب 100 مل» → 400، و
           «اتومافيوتكس» → 200 و4 نتايج فيهم المطلوب). فبندوّر واسع
           وبنفلتر إحنا بالمطابقة التامة. */
        const words = nm.split(/\s+/).filter(Boolean);
        const q = (words[0] && words[0].length >= 4) ? words[0] : words.slice(0, 2).join(" ");
        if (!q) return null;
        const u = `${api}/occ/v2/${site}/products/search?query=${encodeURIComponent(q)}&currentPage=0&pageSize=100&lang=ar`
          + `&fields=${encodeURIComponent("products(code,name)")}`;
        try {
          const r = await fetch(u, { headers: H });
          if (!r.ok) return null;
          const target = norm(nm);
          for (const p of ((await r.json())?.products || [])) {
            if (p.code && norm(stripTags(p.name)) === target) return { item_name: nm, supplier_code: String(p.code) };
          }
        } catch { /* */ }
        return null;
      });
      const hits = found.filter(Boolean) as any[];
      codesUnmatched = nameList.length - hits.length;
      for (let i = 0; i < hits.length; i += 1000) {
        const { data, error } = await supa.rpc("pharma_codes_upsert", { p_rows: hits.slice(i, i + 1000) });
        if (error) { cErr2 = error.message; break; }
        codesFilled += Number(data) || 0;
      }
      // الأكواد اللي لقيناها دلوقتي تتحدّث أسعارها في نفس التشغيلة
      for (const h of hits) if (!codes.includes(h.supplier_code)) codes.push(h.supplier_code);
    }

    let missed = 0;
    const rrows = await pool(codes, cDetail, async (c) => {
      for (let a = 0; a < 2; a++) {
        try {
          const r = await fetch(detUrl(c), { headers: H });
          if (r.ok) {
            const d = await r.json();
            const v = priceOf(d?.pharmacyDiscount?.value ?? null, d?.publicPrice?.value ?? null, d?.price?.value ?? null);
            if (!v) break;                      // الصنف موجود بس من غير سعر — مانلمسوش صفّه
            return { supplier_code: c, price: v.price, discount_perc: v.disc, available: true };
          }
          if (r.status === 404) break;          // خرج من كتالوجهم — مافيش إعادة محاولة
        } catch { /* نعيد */ }
      }
      missed++; return null;
    });
    const got = rrows.filter(Boolean) as any[];
    let updated = 0; let rErr: string | null = null;
    for (let i = 0; i < got.length; i += 1000) {
      const { data, error } = await supa.rpc("pharma_prices_refresh", { p_rows: got.slice(i, i + 1000) });
      if (error) { rErr = error.message; break; }
      updated += Number(data) || 0;
    }
    return jsonRes({ ok: !rErr && !cErr2, mode: "refresh_codes", requested: codes.length, fetched: got.length,
      updated, missed, codes_filled: codesFilled, codes_unmatched: codesUnmatched,
      seconds: Math.round((Date.now() - t0) / 100) / 10, up_error: rErr || cErr2 });
  }

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

  // السعر من صفحة المنتج مش من فهرس البحث — السبب مشروح فوق عند detUrl
  let detailFails = 0;
  let staleSearch = 0;   // كام صنف البحث كان غلط فيه
  const rows = await pool(items, cDetail, async (it) => {
    let adv: number | null = null, dPub: number | null = null, dNet: number | null = null;
    let got = false;
    for (let a = 0; a < 2; a++) {
      try {
        const r = await fetch(detUrl(it.code), { headers: H });
        if (r.ok) {
          const d = await r.json();
          adv = d?.pharmacyDiscount?.value ?? null;
          dPub = d?.publicPrice?.value ?? null;
          dNet = d?.price?.value ?? null;
          got = true; break;
        }
      } catch { /* */ }
    }
    if (!got) detailFails++;
    if (dPub != null && it.pub != null && dPub !== it.pub) staleSearch++;

    /* الخصم زي ما هو: pharmacyDiscount هو الخصم التعاقدي الحقيقي
       (قرار المالك). اللي اتغيّر هو **مصدر السعر** بس — صفحة المنتج
       بدل فهرس البحث القديم، وبنرجع لفهرس البحث لو الصفحة فشلت. */
    const v = priceOf(adv, dPub ?? it.pub, dNet ?? it.net);
    if (!v) return null;
    return { item_name: it.name, price: v.price, discount_perc: v.disc, available: true, supplier_code: it.code };
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
      processed: all.length, upserted, failed_pages: failedPages, detail_fails: detailFails, stale_search: staleSearch,
      cycle_finished: finished, finalized, seconds: secs, up_error: upErr });
  }

  return jsonRes({ ok: !upErr, mode: "chunk", chunk_started: startedIso, from_page: fromPage, to_page: lastPage, total_pages: totalPages, catalog_total: totalResults, processed: all.length, failed_pages: failedPages, detail_fails: detailFails, stale_search: staleSearch, upserted, seconds: secs, up_error: upErr });
});
