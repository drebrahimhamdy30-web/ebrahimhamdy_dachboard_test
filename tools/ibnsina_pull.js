#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   سحب كتالوج «ابن سينا فارما» → store_item_prices
   ═══════════════════════════════════════════════════════════════════
   ⚠️ ليه سكربت محلي مش Edge Function زي فارما؟
      Cloudflare بتاعة ابن سينا بتحجب مراكز البيانات: نفس النداء
      بالحرف بيرجّع 403 (صفحة HTML) من سوبابيز ومن سيرفرنا الذاتي،
      وبيرجّع رد سليم من أي خط مصري عادي. جرّبنا الترويسات كلها
      (Origin/Referer/User-Agent) — الحجب على الـIP. فالسكربت ده
      لازم يشتغل من جهاز في الصيدلية على خط مصري.
      لو ابن سينا سمحوا لعنوان السيرفر بعدين، ننقله Edge Function
      في نص ساعة — المنطق هنا هو هو.

   التشغيل:
     node tools/ibnsina_pull.js --probe    ← تجربة، مابتكتبش أي صف
     node tools/ibnsina_pull.js            ← مزامنة كاملة
     node tools/ibnsina_pull.js --pages 3  ← أول 3 صفحات بس (تجربة كتابة)

   الإعدادات: tools/ibnsina.local.json (مش في git — فيه كلمة السر)
   محتاج Node 18 أو أحدث (fetch جوّه Node).
   ═══════════════════════════════════════════════════════════════════ */

'use strict';
const fs = require('fs');
const path = require('path');

const CFG_PATH = path.join(__dirname, 'ibnsina.local.json');
const API = 'https://portalgateway.ibnsina-pharma.com/api';
const LOGIN_URL = `${API}/Identity/v1.0/portal/Identity/Login`;
const PRODUCTS_URL = `${API}/product/v1/portal/search-products`;
/* الحمل مقصود إنه خفيف على الطرفين:
   • عند ابن سينا: 16 نداء في اليوم كله (PageSize=1000 مجرّب ومقبول)
     بفاصل 800ms — أقل من إنسان بيقلّب الكتالوج في المتصفح.
   • عند قاعدتنا: الكتابة بدفعات 500 صف بفاصل 300ms بدل دفعة واحدة
     كبيرة تقفل الجدول على باقي الشاشات. */
const PAGE_SIZE = 1000;          // مجرّب — بيقبل لحد 1000 في النداء الواحد
const MAX_PAGES = 200;           // حارس ضد اللف اللانهائي
const PAUSE_MS = 800;            // فاصل بين صفحات ابن سينا
const WRITE_CHUNK = 500;         // حجم دفعة الكتابة عندنا
const WRITE_PAUSE_MS = 300;      // فاصل بين دفعات الكتابة

/* ⚠️ الـendpoint ده **لازم** ياخد Name، ومن غيره بيرجّع صفر (مش خطأ —
   صفر). وبـSearchType=0 بيتجاهل الكلمة نفسها ويرجّع الكتالوج كله
   (اتأكد: «بنادول» و«ا» الاتنين رجّعوا نفس الـ15,720). فبنبعت حرف
   واحد كأنه شرط شكلي، ونمشي بالصفحات على الكتالوج كامل. */
const ALL_QUERY = `Name=${encodeURIComponent('ا')}&SearchType=0`;

/* ترويسات المتصفح — البوابة نفسها بتبعتها، ومن غيرها Cloudflare
   بترد 403 حتى من خط مصري. */
const BROWSER = {
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'ar',
  'Origin': 'https://customerportal.ibnsina-pharma.com',
  'Referer': 'https://customerportal.ibnsina-pharma.com/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
};

const args = process.argv.slice(2);
const PROBE = args.includes('--probe');
const LIMIT_PAGES = (() => {
  const i = args.indexOf('--pages');
  return i >= 0 ? Math.max(1, parseInt(args[i + 1]) || 1) : 0;
})();

const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);

function readConfig() {
  if (!fs.existsSync(CFG_PATH)) {
    console.error('\n❌ مفيش ملف إعدادات: ' + CFG_PATH);
    console.error('   انسخ ibnsina.local.example.json باسم ibnsina.local.json واملا user/pass.\n');
    process.exit(1);
  }
  const c = JSON.parse(fs.readFileSync(CFG_PATH, 'utf8'));

  /* التلات حسابات (المعمورة/سيدى بشر/سان ستيفانو) اتقارنوا 2026-09-29:
     نفس الـ15,526 صنف وصفر فرق في أي سعر. فحساب واحد بيكفي، وأي
     حساب منهم يسوى التاني — بناخد أول واحد معبّي. */
  const acc = c.accounts || {};
  const picked = Object.entries(acc).find(([, v]) => v && v.user && v.pass);
  if (picked) { c.account = picked[0]; c.user = picked[1].user; c.pass = picked[1].pass; }

  for (const k of ['user', 'pass', 'supabaseUrl', 'anonKey', 'syncKey']) {
    if (!c[k] || String(c[k]).startsWith('<')) {
      console.error(`\n❌ ناقص «${k}» في ${CFG_PATH}\n`);
      process.exit(1);
    }
  }
  c.account = c.account || 'المعمورة';
  return c;
}

async function login(cfg) {
  const r = await fetch(LOGIN_URL, {
    method: 'POST',
    headers: { ...BROWSER, 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: String(cfg.user), password: String(cfg.pass) })
  });
  const txt = await r.text();
  let j = null; try { j = JSON.parse(txt); } catch { /* صفحة HTML = حجب */ }
  if (!j) {
    throw new Error(`الرد مش JSON (status ${r.status}) — غالبًا Cloudflare حاجبة الجهاز ده. `
      + `جرّب من خط إنترنت مصري عادي.`);
  }
  const token = j?.data?.token;
  if (!r.ok || !token) {
    throw new Error('فشل الدخول: ' + (j?.errorMessage || j?.errorList?.[0] || `status ${r.status}`));
  }
  return { token, pharmacy: j?.data?.pharmacyName || null };
}

async function getPage(token, page) {
  const url = `${PRODUCTS_URL}?${ALL_QUERY}&PageIndex=${page}&PageSize=${PAGE_SIZE}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(url, { headers: { ...BROWSER, Authorization: 'Bearer ' + token } });
      if (r.status === 401 || r.status === 403) return { authFail: true, status: r.status };
      if (r.ok) {
        const j = await r.json();
        return {
          rows: j?.data?.searchResult || [],
          total: j?.data?.totalCount ?? null,
          hasNext: j?.data?.hasNextPage ?? null
        };
      }
    } catch (e) { /* نعيد المحاولة */ }
    await sleep(1200);
  }
  return { failed: true };
}

/* price = سعر الجمهور · pharmacyPrice = سعر الصيدلية بعد الخصم.
   بنخزّن السعر + نسبة الخصم عشان يتقارن بباقي المخازن بنفس المعيار.

   ⚠️ ابن سينا مابيقولش في الكتالوج الصنف متوفر ولا لأ — التوفر عندهم
   بيتشيك وقت الطلب لكل صنف لوحده. فبنستخدم updatedOnUtc كأقرب إشارة:
   في سوق سعره بيتحرّك كل شهرين، صنف مااتغيّرش سعره من سنة = ميّت
   عمليًا. بنعلّمه «مش متاح» بدل ما نمسحه، عشان لو رجع يبان تاني. */
const STALE_MONTHS = 12;
const STALE_BEFORE = (() => { const d = new Date(); d.setMonth(d.getMonth() - STALE_MONTHS); return d.toISOString(); })();

function toRow(x) {
  const name = String(x.nameAr || x.name || '').replace(/\s+/g, ' ').trim();
  if (!name) return null;
  const pub = Number(x.price);
  const net = Number(x.pharmacyPrice);
  let price, disc;
  if (Number.isFinite(pub) && pub > 0 && Number.isFinite(net) && net > 0) {
    price = pub;
    disc = Math.min(Math.max(Math.round((1 - net / pub) * 10000) / 100, 0), 100);
  } else if (Number.isFinite(net) && net > 0) {
    price = net; disc = 0;
  } else return null;   // سعر صفر = مش بيتباع
  const upd = String(x.updatedOnUtc || '');
  return {
    item_name: name, price, discount_perc: disc,
    available: !(upd && upd < STALE_BEFORE),
    supplier_code: x.itemCode ? String(x.itemCode) : null
  };
}

async function rpc(cfg, fn, body) {
  const r = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: cfg.anonKey, Authorization: 'Bearer ' + cfg.anonKey, 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn} → HTTP ${r.status}: ${t.slice(0, 200)}`);
  try { return JSON.parse(t); } catch { return t; }
}

(async () => {
  const cfg = readConfig();
  const t0 = Date.now();
  const startedIso = new Date().toISOString();
  let scanned = 0, upserted = 0, unavailable = 0, stale = 0;

  try {
    log('🔐 جارٍ الدخول…');
    const { token, pharmacy } = await login(cfg);
    log(`✓ دخلنا${pharmacy ? ' — ' + pharmacy : ''}`);

    const first = await getPage(token, 1);
    if (first.authFail) throw new Error('التوكن مرفوض (status ' + first.status + ')');
    if (first.failed) throw new Error('فشل جلب أول صفحة');

    const total = Number(first.total) || 0;
    const totalPages = total ? Math.ceil(total / PAGE_SIZE) : 1;
    log(`📦 الكتالوج: ${total.toLocaleString('ar-EG')} صنف · ${totalPages} صفحة`);

    if (PROBE) {
      log('\n— عيّنة من أول صفحة —');
      (first.rows || []).slice(0, 8).forEach(x => {
        const row = toRow(x);
        log(`  ${x.itemCode}  ${row ? row.item_name : '(بدون اسم)'}`);
        log(`     جمهور ${x.price} · صيدلية ${x.pharmacyPrice} · خصم ${row ? row.discount_perc : '?'}%`
          + `  صلاحية ${[x.expireLastMonth, x.expireLastYear].filter(Boolean).join('/') || '—'}`);
      });
      log(`\n✓ التجربة تمام — مفيش حاجة اتكتبت. شغّل من غير --probe للمزامنة الكاملة.`);
      return;
    }

    const lastPage = LIMIT_PAGES ? Math.min(LIMIT_PAGES, totalPages) : Math.min(totalPages, MAX_PAGES);
    let buffer = [];
    const flush = async () => {
      while (buffer.length) {
        const chunk = buffer.splice(0, WRITE_CHUNK);
        const n = await rpc(cfg, 'ibnsina_prices_upsert', { p_key: cfg.syncKey, p_rows: chunk });
        upserted += Number(n) || 0;
        if (buffer.length) await sleep(WRITE_PAUSE_MS);
      }
    };

    for (let p = 1; p <= lastPage; p++) {
      const res = p === 1 ? first : await getPage(token, p);
      if (res.authFail) throw new Error('التوكن انتهى في الصفحة ' + p);
      if (res.failed) { log(`  ⚠️ صفحة ${p} فشلت — كمّلنا`); continue; }
      const rows = (res.rows || []).map(toRow).filter(Boolean);
      scanned += rows.length;
      stale += rows.filter(r => !r.available).length;
      buffer.push(...rows);
      if (buffer.length >= WRITE_CHUNK) await flush();
      if (p % 10 === 0 || p === lastPage) {
        log(`  … صفحة ${p}/${lastPage} · اتقرا ${scanned} · اتكتب ${upserted}`);
      }
      if (p < lastPage) await sleep(PAUSE_MS);
    }
    await flush();

    // الإنهاء بيتعمل بس لما نكون مشينا الكتالوج كله
    if (!LIMIT_PAGES) {
      unavailable = Number(await rpc(cfg, 'ibnsina_prices_finalize',
        { p_key: cfg.syncKey, p_before: startedIso })) || 0;
    }

    const secs = Math.round((Date.now() - t0) / 100) / 10;
    await rpc(cfg, 'ibnsina_sync_report', {
      p_key: cfg.syncKey,
      p_row: { account: cfg.account, scanned, upserted, unavailable, ok: true, seconds: secs, source: 'local' }
    });
    log(`\n✅ خلصت في ${secs}ث — اتقرا ${scanned} · اتحدّث ${upserted}`);
    log(`   منهم ${stale} سعرهم مااتغيّرش من ${STALE_MONTHS} شهر فاتعلّموا «مش متاح»`
      + (unavailable ? ` · و${unavailable} اختفوا من الكتالوج` : ''));
  } catch (e) {
    const secs = Math.round((Date.now() - t0) / 100) / 10;
    log(`\n❌ ${e.message}`);
    try {
      await rpc(cfg, 'ibnsina_sync_report', {
        p_key: cfg.syncKey,
        p_row: { account: cfg.account, scanned, upserted, unavailable, ok: false,
                 error: String(e.message).slice(0, 300), seconds: secs, source: 'local' }
      });
    } catch { /* السجل مش أهم من الرسالة اللي فوق */ }
    process.exit(1);
  }
})();
