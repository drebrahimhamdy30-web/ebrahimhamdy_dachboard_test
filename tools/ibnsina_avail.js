#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   توفر ابن سينا اللحظي — نبضة كل ساعة تغطّي الكتالوج في 24 ساعة
   ═══════════════════════════════════════════════════════════════════
   ليه محتاجينه: على عكس فارما (stockLevelStatus بتاعهم دايمًا inStock
   فبلا قيمة)، ابن سينا بيدّي توفر حقيقي + **أقصى كمية للطلب**. عيّنة
   20 صنف طلّعت 45% غير متاح — يعني من غير الفحص ده نص أصناف المقارنة
   مش هتقدر تطلبها أصلًا.

   الحمل: 200 صنف في النداء الواحد (~2 ثانية). الكتالوج 15.5 ألف =
   78 نداء. مقسومة على 24 ساعة = **3–4 نداءات في الساعة** — أخف من
   موظف بيتصفّح.

   مفيش مؤشّر ولا جدول حالة: كل نبضة بتاخد الأصناف **الأقدم فحصًا**
   (`avail_checked_at nulls first`). ده بيوزّع نفسه لوحده، وبيلمّ
   الأصناف الجديدة أول ما تدخل، وبيتعافى لو نبضة فشلت.

   ⚠️ لازم يشتغل من جهاز على خط مصري — Cloudflare بتاعتهم بتحجب
      مراكز البيانات. راجع tools/ibnsina_pull.js.

   التشغيل:
     node tools/ibnsina_avail.js              ← نبضة (1/24 من الكتالوج)
     node tools/ibnsina_avail.js --all        ← الكتالوج كله مرة واحدة
     node tools/ibnsina_avail.js --limit 400  ← عدد أصناف محدد
   ═══════════════════════════════════════════════════════════════════ */

'use strict';
const fs = require('fs');
const path = require('path');

const CFG = JSON.parse(fs.readFileSync(path.join(__dirname, 'ibnsina.local.json'), 'utf8'));
const API = 'https://portalgateway.ibnsina-pharma.com/api';
const CHUNK = 200;            // مجرّب: 200 صنف = 667KB في ~2 ثانية
const PAUSE_MS = 1500;        // فاصل بين الدفعات
const SLICES_PER_DAY = 24;    // نبضة كل ساعة
const BROWSER = {
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'ar',
  'Origin': 'https://customerportal.ibnsina-pharma.com',
  'Referer': 'https://customerportal.ibnsina-pharma.com/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);

const args = process.argv.slice(2);
const ALL = args.includes('--all');
const LIMIT = (() => { const i = args.indexOf('--limit'); return i >= 0 ? Math.max(1, parseInt(args[i + 1]) || 0) : 0; })();

async function rpc(fn, body) {
  const r = await fetch(`${CFG.supabaseUrl}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + CFG.anonKey, 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn} → HTTP ${r.status}: ${t.slice(0, 200)}`);
  try { return JSON.parse(t); } catch { return t; }
}

(async () => {
  const t0 = Date.now();
  const acc = Object.entries(CFG.accounts || {}).find(([, v]) => v && v.user && v.pass);
  if (!acc) { console.error('مفيش حساب معبّي في ibnsina.local.json'); process.exit(1); }

  let checked = 0, avail = 0, failedChunks = 0;
  try {
    const lr = await fetch(`${API}/Identity/v1.0/portal/Identity/Login`, {
      method: 'POST', headers: { ...BROWSER, 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: acc[1].user, password: acc[1].pass })
    });
    const txt = await lr.text();
    let lj = null; try { lj = JSON.parse(txt); } catch { /* HTML = حجب */ }
    if (!lj) throw new Error('الرد مش JSON — غالبًا Cloudflare حاجبة الجهاز ده. شغّله من خط مصري.');
    if (!lj?.data?.token) throw new Error('فشل الدخول: ' + (lj.errorMessage || lj.errorList?.[0] || lr.status));
    const H = {
      ...BROWSER, Authorization: 'Bearer ' + lj.data.token, 'Content-Type': 'application/json',
      inputUsername: acc[1].user, orderType: '1', checkPromotions: 'false'
    };
    log(`✓ ${acc[0]} — ${lj.data.pharmacyName}`);

    // الأصناف اللي دورها (الأقدم فحصًا الأول)
    const want = ALL ? 3000 : (LIMIT || Math.ceil(15500 / SLICES_PER_DAY));
    const due = (await rpc('ibnsina_avail_due', { p_key: CFG.syncKey, p_limit: want })) || [];
    const codes = due.map(x => String(x.supplier_code)).filter(Boolean);
    log(`أصناف دورها الفحص: ${codes.length}`);
    if (!codes.length) { log('مفيش حاجة تتفحص.'); return; }

    for (let i = 0; i < codes.length; i += CHUNK) {
      const part = codes.slice(i, i + CHUNK);
      let rows = null;
      for (let a = 0; a < 2 && !rows; a++) {
        try {
          const r = await fetch(`${API}/OnlineOrderAvailability/v1.0/portal/check-items-list-availability`, {
            method: 'POST', headers: H,
            body: JSON.stringify(part.map(c => ({ itemCode: Number(c), quantity: 1, freeQuantity: 0, customerCode: acc[1].user })))
          });
          if (r.ok) rows = (await r.json())?.data || [];
        } catch { /* نعيد */ }
        if (!rows) await sleep(2000);
      }
      if (!rows) { failedChunks++; log(`  ⚠️ دفعة ${i / CHUNK + 1} فشلت — كمّلنا`); continue; }

      /* «متاح» عندهم مش كفاية: الكود بتاعهم بيعتبر الصنف مش قابل
         للطلب لو max <= 0، إلا لو فيه رصيد ROT (مخزون فرع تاني). */
      const out = rows.map(x => {
        const max = Number(x.max) || 0, rotMax = Number(x.rotMaxQty) || 0;
        const usable = x.rot ? Math.max(max, rotMax) : max;
        return {
          supplier_code: String(x.itemCode),
          available: Number(x.availableTypeId) !== 1 && usable > 0,
          max_qty: usable
        };
      });
      const res = await rpc('ibnsina_avail_upsert', { p_key: CFG.syncKey, p_rows: out });
      checked += Number(res?.updated) || 0;
      avail += Number(res?.available) || 0;
      if (i + CHUNK < codes.length) await sleep(PAUSE_MS);
    }

    const secs = Math.round((Date.now() - t0) / 100) / 10;
    log(`\n✅ ${secs}ث — اتفحص ${checked} صنف · متاح ${avail} · غير متاح ${checked - avail}`
      + (failedChunks ? ` · ${failedChunks} دفعة فشلت` : ''));
    await rpc('ibnsina_sync_report', {
      p_key: CFG.syncKey,
      p_row: { account: acc[0], scanned: checked, upserted: avail, ok: failedChunks === 0, seconds: secs, source: 'avail' }
    });
  } catch (e) {
    log(`\n❌ ${e.message}`);
    try {
      await rpc('ibnsina_sync_report', {
        p_key: CFG.syncKey,
        p_row: { account: acc[0], scanned: checked, ok: false, error: String(e.message).slice(0, 300),
                 seconds: Math.round((Date.now() - t0) / 100) / 10, source: 'avail' }
      });
    } catch { /* الرسالة اللي فوق أهم */ }
    process.exit(1);
  }
})();
