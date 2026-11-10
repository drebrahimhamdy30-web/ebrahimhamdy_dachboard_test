/* load_stock_xlsx.js — تحميل أرصدة فرع من تقرير مخزون eplus (xlsx).
 *
 * ليه: 2026-11-10 الوركفلو القديم بدّل جدول المعمورة بنصّه (الأدوية
 * نجحت والكوزمو سقطت) فضاع ~12 ألف صنف. والـAPI بتقع متقطّعة وقت
 * الشغل. التقرير بيدّي الحقيقة كاملة بأكوادنا — **من غير جسر itm_id**،
 * وده مهم: إصلاح اعتمد على الجسر كتب أرقام غلط (كود 6546 اتكتب 465
 * والصح 82) لأن الجسر ربطه بصنف تاني.
 *
 * التشغيل:
 *   node scripts/load_stock_xlsx.js <مجلد xlsx المفكوك> [--branch mamora] [--apply]
 * العرض افتراضي؛ الكتابة بـ--apply.
 *
 * أعمدة التقرير (البيانات فيها عمود أقل من العناوين، فالإزاحة 1):
 *   data[3]=س.البيع  data[5]=الكمية  data[6]=الوحدة
 *   data[7]=الشركة   data[8]=الإسم   data[9]=الكود
 * والكميات بالوحدة الكبرى (عنوان التقرير بيقول «الوحدة كبرى»).
 *
 * الصفوف بتتبني كاملة: الصف الموجود عندنا أساس، والتقرير بيدوس على
 * الكمية والسعر والاسم بس. لو الصنف مش موجود في الفرع، بناخد الوصف من
 * فرع تاني (نفس الكتالوج) وبنحط عليه مخزن الفرع. وآخر حل صف من
 * التقرير لوحده. ليه: `upsert_branch_stock` بيكتب كل أعمدة الجدول،
 * فأي عمود غايب من الـJSON بيتكتب NULL.
 */
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const XLDIR = args.find(a => !a.startsWith('--'));
const BRANCH = (args.find(a => a.startsWith('--branch=')) || '--branch=mamora').split('=')[1];
const APPLY = args.includes('--apply');
if (!XLDIR) { console.error('الاستعمال: node scripts/load_stock_xlsx.js <مجلد> [--branch=mamora] [--apply]'); process.exit(1); }

/* الملف متكتوب بـBOM — JSON.parse بيرفضه */
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

/* ── Supabase ─────────────────────────────────────────────────────── */
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
async function sbUpsert(rows) {
  const r = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/upsert_branch_stock`, {
    method: 'POST',
    headers: { apikey: cfg.serviceKey, Authorization: 'Bearer ' + cfg.serviceKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_branch: BRANCH, p_rows: rows }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error('RPC → ' + r.status + ' ' + t);
  return JSON.parse(t);
}

const num = v => { const n = Number(String(v ?? '').replace(/,/g,'').trim()); return Number.isFinite(n) ? n : 0; };

(async () => {
  const rows = readSheet(XLDIR);
  const head = rows[1] || [];
  if (String(head[head.length-1]).trim() !== 'الكود') {
    throw new Error('آخر عمود في العناوين مش «الكود» — شكل التقرير اتغيّر، راجعه قبل ما تحمّل');
  }
  const xl = new Map();
  for (const r of rows.slice(2)) {
    const code = String(r[9] ?? '').trim();
    if (!code) continue;
    xl.set(code, { qty: num(r[5]), price: num(r[3]), unit: String(r[6] ?? '').trim(),
                   company: String(r[7] ?? '').trim(), name: String(r[8] ?? '').trim() });
  }
  console.log('التقرير      : ' + xl.size + ' صنف');

  const mine = await sbGet(`stock_${BRANCH}?select=*`);
  const byCode = new Map(mine.map(r => [String(r.itm_code), r]));
  console.log('جدول الفرع   : ' + mine.length + ' صف');

  /* الأوصاف من الفروع التانية للأصناف اللي مش عندنا */
  const donors = new Map();
  for (const b of ['san','bishr','seyouf'].filter(b => b !== BRANCH)) {
    for (const r of await sbGet(`stock_${b}?select=*`)) {
      const c = String(r.itm_code);
      if (!byCode.has(c) && !donors.has(c)) donors.set(c, r);
    }
  }
  console.log('أوصاف مُعارة : ' + donors.size + ' صنف من الفروع التانية');

  let kept = 0, fromDonor = 0, bare = 0, changed = 0, bareNow = false;
  const payload = [];
  for (const [code, x] of xl) {
    let base = byCode.get(code);
    if (base) { kept++; }
    else if (donors.has(code)) { base = Object.assign({}, donors.get(code)); fromDonor++; }
    else { base = { itm_code: code }; bare++; }

    const row = Object.assign({}, base);
    delete row.updated_at;
    const cs = num(row.unit_big_small_coeff)  || 1;
    const cm = num(row.unit_big_medium_coeff) || 1;

    row.itm_code             = code;
    row.sto_name             = STORE;
    row.sto_qty_big          = x.qty;
    row.sto_qty_small        = +(x.qty * cs).toFixed(2);
    row.sto_qty_medium       = +(x.qty * cm).toFixed(2);
    row.itm_sell_price_big   = x.price;
    row.itm_sell_price_small = cs ? +(x.price / cs).toFixed(2) : x.price;
    row.itm_sell_price_medium= cm ? +(x.price / cm).toFixed(2) : x.price;
    if (x.name)    row.itm_name_ar      = x.name;
    if (x.company) row.Company_Name_Ar  = x.company;
    if (x.unit && !row.u_name_big) row.u_name_big = x.unit;
    /* الصف الشحيح معاهوش غير الوحدة الكبرى. المعامل 1 فالوحدات
       الصغرى تساويها — أحسن من NULL اللي بتبوّظ عرض الوحدة. */
    if (!row.u_name_small)  row.u_name_small  = row.u_name_big;
    if (!row.u_name_medium) row.u_name_medium = row.u_name_big;
    row.unit_big_small_coeff  = cs;
    row.unit_big_medium_coeff = cm;

    if (!base.sto_qty_big || num(base.sto_qty_big) !== x.qty) changed++;
    row.__bare = (bareNow = !byCode.has(code) && !donors.has(code));
    payload.push(row);
  }
  /* كام صنف شحيح **وله رصيد فعلي**؟ ده اللي بيحدد حجم الأثر: صنف
     شحيح برصيد صفر مالوش تأثير على الطلبيات ولا الشاشات. */
  const bareWithStock = payload.filter(r => r.__bare && num(r.sto_qty_big) > 0).length;
  for (const r of payload) delete r.__bare;

  console.log('');
  console.log('موجود عندنا  : ' + kept);
  console.log('من فرع تاني  : ' + fromDonor);
  console.log('بيانات شحيحة : ' + bare + '  (منهم ' + bareWithStock + ' ليهم رصيد فعلي)');
  console.log('كميته هتتغيّر: ' + changed);
  console.log('الإجمالي     : ' + payload.length);

  const sample = payload.filter(r => ['698','7220','6546'].includes(r.itm_code));
  console.log('\nعيّنة:');
  for (const s of sample) console.log('  ' + s.itm_code + ' · ' + s.itm_name_ar + ' · كمية ' + s.sto_qty_big + ' · سعر ' + s.itm_sell_price_big);

  if (!APPLY) { console.log('\nعرض فقط — شغّل بـ--apply للكتابة'); return; }
  if (payload.length < 20000) throw new Error('رفض: ' + payload.length + ' صف أقل من المتوقع — راجع التقرير');

  let done = 0;
  for (let i = 0; i < payload.length; i += 2000) {
    const res = await sbUpsert(payload.slice(i, i + 2000));
    done += res.kept || 0;
    console.log('  دفعة ' + (i/2000 + 1) + ': kept=' + res.kept + ' skipped=' + res.skipped);
  }
  console.log('\nاتكتب ' + done + ' صف');
})().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
