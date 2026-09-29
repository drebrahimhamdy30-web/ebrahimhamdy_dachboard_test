#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   مقارنة حسابات ابن سينا (فرع × فرع)
   ═══════════════════════════════════════════════════════════════════
   السؤال اللي بتجاوب عليه: هل الكتالوج والأسعار واحدة لكل الفروع
   ولا كل فرع له أسعاره؟ الإجابة بتحدّد نخزّن مخزن واحد «ابن سينا»
   ولا مخزن لكل فرع — فالمقارنة دي قبل أي بناء.

   مابتكتبش أي صف في القاعدة — قراءة وتقرير بس.
   التشغيل: node tools/ibnsina_compare.js
   ═══════════════════════════════════════════════════════════════════ */

'use strict';
const fs = require('fs');
const path = require('path');

const CFG = JSON.parse(fs.readFileSync(path.join(__dirname, 'ibnsina.local.json'), 'utf8'));
const API = 'https://portalgateway.ibnsina-pharma.com/api';
const PAGE_SIZE = 1000;
const ALL_QUERY = `Name=${encodeURIComponent('ا')}&SearchType=0`;
const BROWSER = {
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'ar',
  'Origin': 'https://customerportal.ibnsina-pharma.com',
  'Referer': 'https://customerportal.ibnsina-pharma.com/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);
const money = n => (Math.round(n * 100) / 100).toLocaleString('ar-EG');

async function pullAccount(name, cred) {
  const lr = await fetch(`${API}/Identity/v1.0/portal/Identity/Login`, {
    method: 'POST', headers: { ...BROWSER, 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: String(cred.user), password: String(cred.pass) })
  });
  const txt = await lr.text();
  let j = null; try { j = JSON.parse(txt); } catch { /* HTML = حجب */ }
  if (!j) throw new Error('الرد مش JSON — غالبًا Cloudflare حاجبة الجهاز ده');
  const token = j?.data?.token;
  if (!token) throw new Error(j?.errorMessage || j?.errorList?.[0] || `status ${lr.status}`);

  const H = { ...BROWSER, Authorization: 'Bearer ' + token };
  const items = new Map();
  for (let p = 1; p <= 60; p++) {
    const r = await fetch(`${API}/product/v1/portal/search-products?${ALL_QUERY}&PageIndex=${p}&PageSize=${PAGE_SIZE}`, { headers: H });
    if (!r.ok) throw new Error(`صفحة ${p} → status ${r.status}`);
    const d = (await r.json())?.data;
    const rows = d?.searchResult || [];
    for (const x of rows) {
      if (!x.itemCode) continue;
      // لو الكود اتكرر عند نفس الحساب ناخد الأرخص صافي
      const net = Number(x.pharmacyPrice);
      const prev = items.get(String(x.itemCode));
      if (!prev || (Number.isFinite(net) && net < prev.net)) {
        items.set(String(x.itemCode), {
          name: x.nameAr || x.name || '', pub: Number(x.price), net,
          updated: String(x.updatedOnUtc || '').slice(0, 10)
        });
      }
    }
    if (!d?.hasNextPage || !rows.length) break;
    await sleep(300);
  }
  return { pharmacy: j.data.pharmacyName || name, items };
}

(async () => {
  const accounts = CFG.accounts || {};
  const filled = Object.entries(accounts).filter(([, c]) => c && c.user && c.pass);
  if (filled.length < 2) {
    console.error('\n❌ محتاج حسابين على الأقل معبّيين في tools/ibnsina.local.json\n');
    process.exit(1);
  }

  const pulled = [];
  for (const [name, cred] of filled) {
    process.stdout.write(`🔐 ${name} … `);
    try {
      const res = await pullAccount(name, cred);
      pulled.push({ key: name, ...res });
      log(`✓ ${res.pharmacy} · ${res.items.size.toLocaleString('ar-EG')} صنف`);
    } catch (e) {
      log(`✗ ${e.message}`);
    }
    await sleep(600);
  }
  if (pulled.length < 2) { console.error('\n❌ مانجحش غير حساب واحد — مفيش مقارنة.\n'); process.exit(1); }

  const base = pulled[0];
  log(`\n═══ المقارنة — الأساس: ${base.key} ═══`);

  for (let i = 1; i < pulled.length; i++) {
    const o = pulled[i];
    log(`\n▸ ${o.key} مقابل ${base.key}`);

    const onlyBase = [...base.items.keys()].filter(k => !o.items.has(k));
    const onlyOther = [...o.items.keys()].filter(k => !base.items.has(k));
    const common = [...base.items.keys()].filter(k => o.items.has(k));

    log(`  أصناف مشتركة: ${common.length.toLocaleString('ar-EG')}`);
    log(`  عند ${base.key} بس: ${onlyBase.length.toLocaleString('ar-EG')}  ·  عند ${o.key} بس: ${onlyOther.length.toLocaleString('ar-EG')}`);

    let samePub = 0, sameNet = 0, diffNet = 0, cheaperHere = 0, cheaperThere = 0;
    let maxGap = { code: null, gap: 0 };
    let sumAbsGap = 0;
    const examples = [];
    for (const k of common) {
      const a = base.items.get(k), b = o.items.get(k);
      if (a.pub === b.pub) samePub++;
      if (a.net === b.net) { sameNet++; continue; }
      diffNet++;
      if (b.net < a.net) cheaperThere++; else cheaperHere++;
      const gap = Math.abs(a.net - b.net);
      sumAbsGap += gap;
      if (gap > maxGap.gap) maxGap = { code: k, gap, a, b };
      if (examples.length < 6) examples.push({ k, a, b });
    }

    log(`  سعر الجمهور متطابق: ${samePub.toLocaleString('ar-EG')} من ${common.length.toLocaleString('ar-EG')}`);
    log(`  سعر الصيدلية متطابق: ${sameNet.toLocaleString('ar-EG')}  ·  مختلف: ${diffNet.toLocaleString('ar-EG')}`);

    if (!diffNet) {
      log(`  ✅ مفيش أي فرق في السعر — الحسابين بيشوفوا نفس الأسعار.`);
    } else {
      log(`     منهم أرخص عند ${o.key}: ${cheaperThere}  ·  أرخص عند ${base.key}: ${cheaperHere}`);
      log(`     متوسط الفرق: ${money(sumAbsGap / diffNet)} ج · أكبر فرق: ${money(maxGap.gap)} ج`);
      if (maxGap.a) log(`     (${maxGap.code} ${maxGap.a.name.slice(0, 30)} — ${money(maxGap.a.net)} مقابل ${money(maxGap.b.net)})`);
      log(`\n     أمثلة:`);
      for (const e of examples) {
        log(`       ${e.k} ${e.a.name.slice(0, 30).padEnd(32)} ${base.key}: ${money(e.a.net)}  ${o.key}: ${money(e.b.net)}`);
      }
    }

    if (onlyOther.length) {
      log(`\n     أصناف عند ${o.key} بس (أول 5):`);
      onlyOther.slice(0, 5).forEach(k => log(`       ${k} ${o.items.get(k).name.slice(0, 40)}`));
    }
  }

  log(`\n═══ الخلاصة ═══`);
  const allSame = pulled.slice(1).every(o => {
    const common = [...base.items.keys()].filter(k => o.items.has(k));
    return common.every(k => base.items.get(k).net === o.items.get(k).net)
        && o.items.size === base.items.size;
  });
  log(allSame
    ? '✅ الحسابات كلها بتشوف نفس الكتالوج وبنفس الأسعار → مخزن واحد «ابن سينا» يكفي.'
    : '⚠️ فيه اختلاف → لازم نقرر: مخزن لكل فرع، ولا نخزّن الأرخص، ولا نمشي بحساب واحد.');
})();
