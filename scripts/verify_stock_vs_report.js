/* verify_stock_vs_report.js — مقارنة جدول مخزون فرع بتقرير eplus، صنف بصنف.
 *
 * **قراءة فقط.** مابيكتبش ولا صف.
 *
 * ليه التقرير مش الـSQL المباشر: قاعدة eplus مافيهاش عمود كود مقروء —
 * الاسم والكود مشفّرين في `itm_data` بمفتاح مش عندنا، والجسر اللي
 * بنيناه من المشتريات (`eplus_id_code`) **مش موثوق**: إصلاح اعتمد
 * عليه 2026-11-10 كتب كود 6546 برصيد 465 والصح 82. التقرير بيطبع
 * **أكوادنا** من eplus نفسها، بلا جسر. راجع [[eplus-itmid-code-bridge]].
 *
 * التشغيل:
 *   node scripts/verify_stock_vs_report.js <مجلد xlsx المفكوك> \
 *        --at "2026-11-10 14:30" [--branch=mamora] [--tol=0.01] [--csv=out.csv]
 *
 * ⚠️ `--at` إلزامي = وقت تصدير التقرير بتوقيت القاهرة.
 *    من غيره مفيش طريقة نفرّق بين «غلط حقيقي» و«إحنا أحدث من التقرير»:
 *    الجدول بيتحدّث كل 5 دقايق والتقرير لقطة ثابتة، فأي صنف يتباع بعد
 *    التصدير هيبان مختلف وهو سليم تمامًا.
 *
 *    القاعدة:  مختلف و updated_at >= وقت التصدير  →  طبيعي، إحنا أحدث
 *              مختلف و updated_at <  وقت التصدير  →  **يحتمل** مشكلة
 *
 * ⚠️ والاحتمال ده مش يقين — ودي حدود الأداة لازم تتعرف:
 *    `updated_at` = آخر مرة القيمة **اتغيّرت**، مش آخر مرة **بصّينا**.
 *    الصنف اللي بصّينا عليه ولقيناه زي ما هو بيفضل بختمه القديم.
 *    فالصنف اللي اتحرك في eplus بين آخر جولة والتصدير بيبان «فرق
 *    حقيقي» وهو مجرد تأخّر الـ٥ دقايق العادي.
 *      (حصل فعلًا 2026-11-14 في سيدي بشر: كودين ختمهم 06:47 وتقرير
 *       09:23 — واتصلّحوا لوحدهم 09:25. اتنين من 11,499.)
 *
 *    `--recheck` هو اللي بيحسم: بيعيد قراءة الأكواد المشكوك فيها من
 *    القاعدة دلوقتى. ختم اتحرك بعد التصدير = كان تأخّر وخلاص.
 *    ختم لسه مكانه = فجوة حقيقية محتاجة شغل. شغّله بعد ما جولة
 *    جديدة على الأقل تكون عدّت.
 *
 * أعمدة التقرير (البيانات فيها عمود أقل من العناوين، فالإزاحة 1):
 *   data[3]=س.البيع  data[5]=الكمية  data[6]=الوحدة
 *   data[7]=الشركة   data[8]=الإسم   data[9]=الكود
 * والكميات بالوحدة الكبرى (عنوان التقرير بيقول «الوحدة كبرى») — نفس
 * وحدة `sto_qty_big`. راجع [[unit-trap-strips-vs-boxes]].
 */
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const val = (k, d) => {
  const a = args.find(x => x.startsWith('--' + k + '='));
  if (a) return a.split('=').slice(1).join('=');
  const i = args.indexOf('--' + k);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : d;
};
const XLDIR  = args.find(a => !a.startsWith('--') && !args.includes('--at=' + a) );
const BRANCH = val('branch', 'mamora');
const TOL    = Number(val('tol', '0.01'));
const CSV    = val('csv', '');
const AT     = val('at', '');
const RECHECK = args.includes('--recheck');

if (!XLDIR || !AT) {
  console.error('الاستعمال: node scripts/verify_stock_vs_report.js <مجلد> --at "2026-11-10 14:30" [--branch=mamora] [--csv=out.csv]');
  process.exit(1);
}
/* وقت التصدير بتوقيت القاهرة. الأوفست بيتغيّر مع التوقيت الصيفي،
   فبنخلّي JS تحسبه من المنطقة الزمنية بدل ما نكتب +2 ثابتة —
   الترقيع بأوفست ثابت وقع معانا قبل كده. */
function cairoToUtc(s) {
  const m = s.trim().match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) throw new Error('صيغة --at لازم تكون "YYYY-MM-DD HH:MM" — جالي: ' + s);
  const [, Y, Mo, D, H, Mi, S] = m;
  const guess = Date.UTC(+Y, +Mo - 1, +D, +H, +Mi, +(S || 0));
  // الأوفست الفعلي للقاهرة في اللحظة دي
  const f = new Intl.DateTimeFormat('en-US', { timeZone: 'Africa/Cairo', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const p = Object.fromEntries(f.formatToParts(new Date(guess)).filter(x => x.type !== 'literal').map(x => [x.type, +x.value]));
  const shown = Date.UTC(p.year, p.month - 1, p.day, p.hour === 24 ? 0 : p.hour, p.minute, p.second);
  return new Date(guess - (shown - guess));
}
const CUT = cairoToUtc(AT);

const cfg = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, '.phalix', 'sync_engine.json'), 'utf8').replace(/^﻿/, ''));
const STORE = { mamora: 'الصيدلية', san: 'ابراهيم حمدي 2', bishr: 'ابراهيم حمدي 3', seyouf: 'السيوف' }[BRANCH];
if (!STORE) { console.error('فرع غير معروف: ' + BRANCH); process.exit(1); }

/* ── قراءة xlsx بلا مكتبات (الملف zip فيه XML) ───────────────────── */
function readSheet(dir) {
  const unesc = s => s.replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"')
    .replace(/&apos;/g,"'").replace(/&#(\d+);/g,(m,d)=>String.fromCharCode(+d)).replace(/&amp;/g,'&');
  const ss = [];
  for (const m of fs.readFileSync(dir + '/xl/sharedStrings.xml', 'utf8').matchAll(/<si>([\s\S]*?)<\/si>/g)) {
    let t = ''; for (const tm of m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)) t += tm[1];
    ss.push(unesc(t));
  }
  const colOf = ref => { let n = 0; for (const ch of ref.replace(/\d+/g,'')) n = n*26 + (ch.charCodeAt(0)-64); return n-1; };
  const rows = [];
  for (const rm of fs.readFileSync(dir + '/xl/worksheets/Sheet1.xml', 'utf8').matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const cells = [];
    for (const cm of rm[1].matchAll(/<c r="([A-Z]+\d+)"([^>]*)>([\s\S]*?)<\/c>/g)) {
      const vm = cm[3].match(/<v>([\s\S]*?)<\/v>/);
      let val = vm ? vm[1] : '';
      if (/t="s"/.test(cm[2])) val = ss[+val] ?? '';
      else if (/t="(inlineStr|str)"/.test(cm[2])) { const tm = cm[3].match(/<t[^>]*>([\s\S]*?)<\/t>/); val = tm ? unesc(tm[1]) : ''; }
      else val = unesc(val);
      cells[colOf(cm[1])] = val;
    }
    rows.push(cells);
  }
  return rows;
}

async function sbGet(pathq) {
  const out = []; let from = 0; const step = 1000;
  for (;;) {
    const sep = pathq.includes('?') ? '&' : '?';
    const r = await fetch(`${cfg.supabaseUrl}/rest/v1/${pathq}${sep}limit=${step}&offset=${from}`,
      { headers: { apikey: cfg.serviceKey, Authorization: 'Bearer ' + cfg.serviceKey } });
    if (!r.ok) throw new Error('GET ' + pathq + ' → ' + r.status + ' ' + await r.text());
    const page = await r.json();
    out.push(...page);
    if (page.length < step) break;
    from += step;
  }
  return out;
}

const num = v => { const n = Number(String(v ?? '').replace(/,/g,'').trim()); return Number.isFinite(n) ? n : 0; };
const eg  = n => Math.round(n).toLocaleString('en-US');

(async () => {
  const rows = readSheet(XLDIR);
  const head = rows[1] || [];
  if (String(head[head.length-1]).trim() !== 'الكود') {
    throw new Error('آخر عمود في العناوين مش «الكود» — شكل التقرير اتغيّر، راجعه قبل المقارنة');
  }
  const xl = new Map();
  for (const r of rows.slice(2)) {
    const code = String(r[9] ?? '').trim();
    if (!code) continue;
    xl.set(code, { qty: num(r[5]), price: num(r[3]), name: String(r[8] ?? '').trim() });
  }

  const mine = await sbGet(`stock_${BRANCH}?select=itm_code,itm_name_ar,sto_qty_big,itm_sell_price_big,sto_name,updated_at`);
  const db = new Map(mine.map(r => [String(r.itm_code), r]));

  console.log('الفرع          : ' + BRANCH + ' (' + STORE + ')');
  console.log('وقت التصدير    : ' + AT + ' القاهرة');
  console.log('تقرير eplus    : ' + xl.size.toLocaleString('en-US') + ' صنف');
  console.log('جدولنا         : ' + db.size.toLocaleString('en-US') + ' صنف');

  const real = [], newer = [], priceDiff = [], newerPrice = [], onlyEplus = [], onlyUs = [];
  let same = 0, tEplusQty = 0, tUsQty = 0, tEplusVal = 0, tUsVal = 0;

  for (const [code, x] of xl) {
    tEplusQty += x.qty; tEplusVal += x.qty * x.price;
    const r = db.get(code);
    if (!r) { onlyEplus.push({ code, name: x.name, qty: x.qty }); continue; }
    const ourQty   = num(r.sto_qty_big);
    const ourPrice = num(r.itm_sell_price_big);
    const stamp    = new Date(r.updated_at);
    const qOk = Math.abs(ourQty - x.qty) <= TOL;
    const pOk = Math.abs(ourPrice - x.price) <= TOL;
    if (qOk && pOk) { same++; continue; }
    const row = { code, name: x.name, eplus: x.qty, ours: ourQty, gap: +(ourQty - x.qty).toFixed(3),
                  ePrice: x.price, oPrice: ourPrice, at: r.updated_at };
    /* نفس حكم الختم على الاتنين: الكمية بتتغيّر بالبيع، والسعر بتعديل
       في eplus — والحالتين شرعيتين لو حصلوا بعد التصدير.
       (اتأكد 2026-11-10: كود 66949 سعره 70←78 اتعدّل 12:34 وتقرير
       الصبح 11:00، فكان بيتحسب «محتاج مراجعة» وهو إحنا أحدث.) */
    const fresh = stamp >= CUT;
    if (!qOk) (fresh ? newer : real).push(row);
    if (!pOk) (fresh ? newerPrice : priceDiff).push(row);
  }
  for (const [code, r] of db) {
    if (xl.has(code)) { const q = num(r.sto_qty_big); tUsQty += q; tUsVal += q * num(r.itm_sell_price_big); continue; }
    const q = num(r.sto_qty_big);
    tUsQty += q; tUsVal += q * num(r.itm_sell_price_big);
    onlyUs.push({ code, name: r.itm_name_ar, qty: q, at: r.updated_at });
  }

  const pct = n => (100 * n / Math.max(xl.size, 1)).toFixed(2) + '%';
  console.log('');
  console.log('مطابق تمامًا   : ' + same.toLocaleString('en-US') + '  (' + pct(same) + ')');
  console.log('إحنا أحدث (كمية): ' + newer.length + '  ← اتباع بعد التصدير، سليم');
  console.log('إحنا أحدث (سعر) : ' + newerPrice.length + '  ← السعر اتعدّل بعد التصدير، سليم');
  console.log('✗ فرق حقيقي    : ' + real.length + '   ← آخر تحديث قبل التصدير');
  console.log('✗ فرق في السعر : ' + priceDiff.length);
  console.log('✗ في eplus بس  : ' + onlyEplus.length + '   (منهم ' + onlyEplus.filter(x => x.qty > 0).length + ' ليهم رصيد)');
  console.log('✗ عندنا بس     : ' + onlyUs.length + '   (منهم ' + onlyUs.filter(x => x.qty > 0).length + ' ليهم رصيد)');
  console.log('');
  console.log('الوحدات  eplus : ' + eg(tEplusQty) + '   |  عندنا ' + eg(tUsQty) + '   |  فرق ' + eg(tUsQty - tEplusQty));
  console.log('القيمة   eplus : ' + eg(tEplusVal) + ' ج |  عندنا ' + eg(tUsVal) + ' ج |  فرق ' + eg(tUsVal - tEplusVal) + ' ج');

  const show = (title, list, fmt) => {
    if (!list.length) return;
    console.log('\n' + title + ' (أكبر ' + Math.min(list.length, 25) + '):');
    list.slice(0, 25).forEach(x => console.log('  ' + fmt(x)));
    if (list.length > 25) console.log('  … و' + (list.length - 25) + ' غيرهم');
  };
  real.sort((a, b) => Math.abs(b.gap) - Math.abs(a.gap));
  onlyEplus.sort((a, b) => b.qty - a.qty);
  onlyUs.sort((a, b) => b.qty - a.qty);
  show('✗ فروق حقيقية', real, x =>
    x.code.padEnd(10) + ' eplus=' + String(x.eplus).padEnd(10) + ' عندنا=' + String(x.ours).padEnd(10) +
    ' فرق=' + String(x.gap).padEnd(9) + ' ختم=' + x.at.slice(11, 19) + '  ' + (x.name || '').slice(0, 28));
  show('✗ فروق سعر', priceDiff, x =>
    x.code.padEnd(10) + ' eplus=' + String(x.ePrice).padEnd(9) + ' عندنا=' + String(x.oPrice).padEnd(9) + '  ' + (x.name || '').slice(0, 30));
  show('✗ في eplus ومش عندنا', onlyEplus, x => x.code.padEnd(10) + ' كمية=' + String(x.qty).padEnd(9) + '  ' + (x.name || '').slice(0, 34));
  show('✗ عندنا ومش في eplus', onlyUs,   x => x.code.padEnd(10) + ' كمية=' + String(x.qty).padEnd(9) + '  ' + (x.name || '').slice(0, 34));

  /* ── إعادة فحص: تأخّر ولا فجوة؟ ──────────────────────────────────
     قراءة طازجة للأكواد المشكوك فيها. لو ختمها اتحرك بعد التصدير
     يبقى جولة لاحقة مسكتها — كان تأخّر مش ثقب. */
  let lag = 0, stuck = [];
  if (RECHECK && (real.length || priceDiff.length)) {
    const codes = [...new Set([...real, ...priceDiff].map(x => x.code))];
    const q = s => '"' + String(s).replace(/"/g, '\\"') + '"';
    const now = new Map();
    for (let i = 0; i < codes.length; i += 150) {   // الـURL ليه طول
      const part = codes.slice(i, i + 150).map(c => q(c)).join(',');
      const got = await sbGet(`stock_${BRANCH}?select=itm_code,sto_qty_big,itm_sell_price_big,updated_at`
                              + `&itm_code=in.(${encodeURIComponent(part)})`);
      got.forEach(r => now.set(String(r.itm_code), r));
    }
    console.log('\n── إعادة فحص (' + codes.length + ' كود) ──');
    for (const code of codes) {
      const r = now.get(code);
      const was = (real.find(x => x.code === code) || priceDiff.find(x => x.code === code) || {});
      if (!r) { stuck.push({ code, why: 'اختفى من الجدول' }); continue; }
      if (new Date(r.updated_at) >= CUT) {
        lag++;
        console.log('  ✓ ' + code.padEnd(10) + ' اتحدّث ' + r.updated_at.slice(11, 19) +
          ' (بعد التصدير) → كمية ' + r.sto_qty_big + ' مقابل ' + was.eplus + ' في التقرير');
      } else {
        stuck.push({ code, why: 'ختمه لسه ' + r.updated_at.slice(11, 19) });
        console.log('  ✗ ' + code.padEnd(10) + ' ختمه لسه ' + r.updated_at.slice(11, 19) +
          ' → لا جولة لمسته. فجوة حقيقية.');
      }
    }
    console.log('  الخلاصة: ' + lag + ' تأخّر عادي · ' + stuck.length + ' فجوة حقيقية');
  }

  if (CSV) {
    const esc = s => '"' + String(s ?? '').replace(/"/g, '""') + '"';
    const lines = ['النوع,الكود,الاسم,eplus,عندنا,الفرق,آخر_تحديث'];
    for (const x of real)      lines.push(['فرق حقيقي', x.code, x.name, x.eplus, x.ours, x.gap, x.at].map(esc).join(','));
    for (const x of newer)     lines.push(['إحنا أحدث', x.code, x.name, x.eplus, x.ours, x.gap, x.at].map(esc).join(','));
    for (const x of priceDiff)  lines.push(['فرق سعر',     x.code, x.name, x.ePrice, x.oPrice, '', x.at].map(esc).join(','));
    for (const x of newerPrice) lines.push(['سعر أحدث',    x.code, x.name, x.ePrice, x.oPrice, '', x.at].map(esc).join(','));
    for (const x of onlyEplus) lines.push(['في eplus بس', x.code, x.name, x.qty, '', '', ''].map(esc).join(','));
    for (const x of onlyUs)    lines.push(['عندنا بس',    x.code, x.name, '', x.qty, '', x.at].map(esc).join(','));
    fs.writeFileSync(CSV, '﻿' + lines.join('\r\n'), 'utf8');   // BOM عشان إكسل يقرا العربي
    console.log('\nالتفاصيل الكاملة: ' + CSV);
  }

  /* بعد إعادة الفحص اللي اتصلّح مابيتعدّش — كان تأخّر مش خطأ */
  const bad = (RECHECK ? stuck.length : real.length + priceDiff.length)
            + onlyEplus.filter(x => x.qty > 0).length + onlyUs.filter(x => x.qty > 0).length;
  console.log('\n' + (bad === 0
    ? 'النتيجة: تطابق تام — ولا فرق واحد غير مفسَّر.'
      + (RECHECK && lag ? ' (' + lag + ' كان تأخّر جولة واتصلّح لوحده)' : '')
    : 'النتيجة: ' + bad + ' صنف محتاج مراجعة.'));
})().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
