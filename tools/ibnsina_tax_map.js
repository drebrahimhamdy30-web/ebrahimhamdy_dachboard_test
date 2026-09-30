#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   استنتاج قاعدة الضريبة لابن سينا من الفواتير الحقيقية
   ═══════════════════════════════════════════════════════════════════
   المشكلة: الكتالوج بيدّي `pharmacyPrice` **قبل الضريبة**، وفيه أصناف
   خاضعة لـ14% وأصناف معفاة، ومفيش علَم في الكتالوج يفرّق. لو ضربنا
   الكل ×1.14 هنغلط في المعفى، ولو سبناه هنغلط في الخاضع — وفي
   الحالتين «أرخص مخزن» بيطلع قرار شراء غلط.

   الفكرة: بنود الفاتورة فيها `salesTaxAmount` صريحة = مرجع مقطوع فيه
   (ده اللي اتدفع فعلًا). ونداء التوفر بيرجّع تصنيف الصنف
   (itemGroupCode / itemCategory / itemClassCode). فبنجمع الاتنين على
   عيّنة كبيرة ونشوف: هل التصنيف بيتنبّأ بالضريبة؟
   لو أيوه → عندنا قاعدة لحظية تنفع على الكتالوج كله وماحتاجناش فواتير.
   لو لأ → بنستعمل الفواتير كسجل بيتحدّث، والباقي «غير مؤكد».

   ⚠️ الضريبة في الفاتورة للسطر كله، فلازم نقسم على الكمية عشان
      نطلّع نسبة الوحدة — من غير كده بتطلع 28% و42% (مضاعفات 14).

   التشغيل على دفعات (بيكمّل من حيث وقف):
     node tools/ibnsina_tax_map.js --n 60     ← 60 فاتورة زيادة
     node tools/ibnsina_tax_map.js --classify ← يجيب تصنيف المعروفين
     node tools/ibnsina_tax_map.js --report   ← التقرير بدون أي نداء
   الناتج: tools/ibnsina_tax_map.json (مستثنى من git)
   ═══════════════════════════════════════════════════════════════════ */

'use strict';
const fs = require('fs');
const path = require('path');

const CFG = JSON.parse(fs.readFileSync(path.join(__dirname, 'ibnsina.local.json'), 'utf8'));
const OUT = path.join(__dirname, 'ibnsina_tax_map.json');
const API = 'https://portalgateway.ibnsina-pharma.com/api';
const BROWSER = {
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'ar',
  'Origin': 'https://customerportal.ibnsina-pharma.com',
  'Referer': 'https://customerportal.ibnsina-pharma.com/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
};
const INV_PAUSE = 600, CLS_PAUSE = 800, CLS_CHUNK = 20;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);

const args = process.argv.slice(2);
const has = f => args.includes(f);
const num = (f, d) => { const i = args.indexOf(f); return i >= 0 ? (parseInt(args[i + 1]) || d) : d; };

const load = () => { try { return JSON.parse(fs.readFileSync(OUT, 'utf8')); } catch { return { doneInvoices: [], items: {} }; } };
const save = s => fs.writeFileSync(OUT, JSON.stringify(s, null, 1));

async function login() {
  const acc = Object.entries(CFG.accounts || {}).find(([, v]) => v && v.user && v.pass);
  if (!acc) { console.error('مفيش حساب معبّي في ibnsina.local.json'); process.exit(1); }
  const j = await (await fetch(`${API}/Identity/v1.0/portal/Identity/Login`, {
    method: 'POST', headers: { ...BROWSER, 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: acc[1].user, password: acc[1].pass })
  })).json();
  if (!j?.data?.token) { console.error('فشل الدخول: ' + (j?.errorMessage || j?.errorList?.[0] || '')); process.exit(1); }
  log(`✓ ${acc[0]} — ${j.data.pharmacyName}`);
  return { user: acc[1].user, H: { ...BROWSER, Authorization: 'Bearer ' + j.data.token, 'Content-Type': 'application/json' } };
}

/* ── 1) الحقيقة من الفواتير ─────────────────────────────────────── */
async function pullInvoices(ctx, state, want, stopWhenNoNew) {
  const seen = new Set(state.doneInvoices);
  const todo = [];
  for (let p = 1; p <= 30 && todo.length < want; p++) {
    const r = await fetch(`${API}/payment/v1/portal/invoices/search?pageNumber=${p}&pageSize=50`, { headers: ctx.H });
    if (!r.ok) break;
    const l = (await r.json())?.data?.invoicesList || [];
    if (!l.length) break;
    const before = todo.length;
    for (const inv of l) if (!seen.has(inv.id) && todo.length < want) todo.push({ id: inv.id, date: String(inv.invoiceDate || '') });
    /* الفواتير بتيجي من الأحدث للأقدم. في التشغيل اليومي لو صفحة
       كاملة مفيهاش ولا فاتورة جديدة، اللي بعدها أقدم منها فأكيد
       مقرية — فبنقف بدل ما نلف على 8 صفحات كل يوم على الفاضي. */
    if (stopWhenNoNew && todo.length === before) break;
    await sleep(400);
  }
  log(`فواتير جديدة: ${todo.length}`);
  for (let i = 0; i < todo.length; i++) {
    try {
      const r = await fetch(`${API}/financialHistory/v1.0/portal/invoice-details?id=${todo[i].id}`, { headers: ctx.H });
      if (r.ok) {
        for (const it of ((await r.json())?.data?.invoiceProductDto || [])) {
          const code = String(it.productCode || '').trim();
          const qty = Number(it.quantity) || 1;
          const ph = Number(it.pharmacyPrice), tx = Number(it.salesTaxAmount);
          if (!code || !(ph > 0) || !Number.isFinite(tx)) continue;
          // ⚠️ الضريبة للسطر كله — القسمة على الكمية شرط
          const rate = tx > 0 ? Math.round((tx / (ph * qty)) * 10000) / 100 : 0;
          const prev = state.items[code] || {};
          const taxed = tx > 0;
          /* ⚠️ الأحدث يكسب — **بتاريخ الفاتورة** مش بترتيب القراءة.
             الحالة بتتغيّر فعلًا: 3 أصناف اتشافوا مرة بضريبة ومرة من
             غيرها. الاعتماد على «أول قراءة هي الأحدث» كان صح في
             المسح الأولي بس (بيمشي من الأحدث للأقدم في تشغيلة واحدة)،
             وبيبقى **غلط** في التشغيل اليومي لأن الفاتورة الجديدة
             أحدث من كل المخزّن، فكانت هتتجاهل وتفضل الحالة القديمة.
             التواريخ ISO فالمقارنة النصية بتساوي المقارنة الزمنية. */
          const when = todo[i].date || '';
          const newer = !prev.when || when >= prev.when;
          state.items[code] = {
            ...prev,
            taxed: newer ? taxed : prev.taxed,
            rate:  newer ? (taxed ? rate : 0) : prev.rate,
            when:  newer ? when : prev.when,
            mixed: prev.taxed != null && prev.taxed !== taxed ? true : (prev.mixed || false),
            name: it.productName || prev.name,
            pub: Number(it.publicPrice) || prev.pub,
            ph, seen: (prev.seen || 0) + 1
          };
        }
        state.doneInvoices.push(todo[i].id);
      }
    } catch { /* نكمّل */ }
    if ((i + 1) % 10 === 0 || i === todo.length - 1) {
      save(state);
      log(`  … ${i + 1}/${todo.length} فاتورة · ${Object.keys(state.items).length} صنف معروف`);
    }
    if (i < todo.length - 1) await sleep(INV_PAUSE);
  }
}

/* ── 2) التصنيف اللحظي لنفس الأصناف ─────────────────────────────── */
async function classify(ctx, state) {
  const need = Object.keys(state.items).filter(c => state.items[c].group === undefined);
  log(`أصناف محتاجة تصنيف: ${need.length}`);
  for (let i = 0; i < need.length; i += CLS_CHUNK) {
    const part = need.slice(i, i + CLS_CHUNK);
    try {
      const r = await fetch(`${API}/OnlineOrderAvailability/v1.0/portal/check-items-list-availability`, {
        method: 'POST',
        headers: { ...ctx.H, inputUsername: ctx.user, orderType: '1', checkPromotions: 'false' },
        body: JSON.stringify(part.map(c => ({ itemCode: Number(c), quantity: 1, freeQuantity: 0, customerCode: ctx.user })))
      });
      if (r.ok) {
        for (const x of ((await r.json())?.data || [])) {
          const p = x.product || {}, c = String(x.itemCode);
          if (!state.items[c]) continue;
          state.items[c].group = p.itemGroupCode ?? null;
          state.items[c].cat = p.itemCategory ?? null;
          state.items[c].cls = p.itemClassCode ?? null;
        }
      }
    } catch { /* نكمّل */ }
    // اللي مارجعش من السيرفر نعلّمه عشان مانعيدش نسأل عنه
    part.forEach(c => { if (state.items[c].group === undefined) state.items[c].group = '(مش راجع)'; });
    save(state);
    process.stdout.write(`  … ${Math.min(i + CLS_CHUNK, need.length)}/${need.length}\r`);
    if (i + CLS_CHUNK < need.length) await sleep(CLS_PAUSE);
  }
  log('');
}

/* ── 3) التقرير: هل التصنيف بيتنبّأ بالضريبة؟ ───────────────────── */
function report(state) {
  const all = Object.entries(state.items);
  const known = all.filter(([, v]) => v.taxed != null);
  const taxed = known.filter(([, v]) => v.taxed).length;
  log(`\n═══ الحصيلة ═══`);
  log(`فواتير: ${state.doneInvoices.length}  ·  أصناف معروفة الضريبة: ${known.length}  (خاضع ${taxed} · معفى ${known.length - taxed})`);
  const mixed = known.filter(([, v]) => v.mixed);
  if (mixed.length) log(`⚠️ أصناف اتحسبت مرة بضريبة ومرة من غيرها: ${mixed.length}`);
  const rates = {};
  known.forEach(([, v]) => { if (v.taxed) rates[v.rate] = (rates[v.rate] || 0) + 1; });
  log(`نِسَب الضريبة للوحدة: ` + Object.entries(rates).map(([r, c]) => `${r}% (${c})`).join(' · '));

  const dims = [['itemGroupCode', 'group'], ['itemCategory', 'cat'], ['itemClassCode', 'cls'],
                ['group+cat+cls', null]];
  for (const [label, key] of dims) {
    const tab = {};
    let n = 0;
    for (const [, v] of known) {
      if (v.group === undefined || v.group === '(مش راجع)') continue;
      const k = key ? String(v[key] ?? '(فاضي)')
                    : `${v.group ?? '—'} / ${v.cat ?? '—'} / ${v.cls ?? '—'}`;
      tab[k] = tab[k] || { t: 0, e: 0 }; v.taxed ? tab[k].t++ : tab[k].e++; n++;
    }
    if (!n) { log(`\n${label}: مفيش تصنيف لسه — شغّل --classify`); continue; }
    const rows = Object.entries(tab).sort((a, b) => (b[1].t + b[1].e) - (a[1].t + a[1].e));
    const pure = rows.filter(([, v]) => v.t === 0 || v.e === 0);
    const covered = pure.reduce((s, [, v]) => s + v.t + v.e, 0);
    log(`\n── ${label} ── (${n} صنف · القاعدة بتحسم ${covered} = ${Math.round(covered / n * 100)}%)`);
    rows.slice(0, 12).forEach(([k, v]) => {
      const tot = v.t + v.e;
      const verdict = v.e === 0 ? '✅ خاضع دايمًا' : v.t === 0 ? '✅ معفى دايمًا' : `⚠️ مخلوط (${Math.round(v.t / tot * 100)}% خاضع)`;
      log('  ' + String(k).padEnd(22) + `خاضع ${String(v.t).padEnd(4)} معفى ${String(v.e).padEnd(4)} ${verdict}`);
    });
  }
  log(`\nالملف: ${OUT}`);
}

/* ── 4) الرفع للقاعدة ───────────────────────────────────────────
   الخريطة لازم تعيش في القاعدة مش في ملف على جهاز، عشان المزامنة
   تستعملها وعشان الشاشة تعرف تفرّق بين المؤكد والمقدّر. */
async function push(state) {
  const rows = Object.entries(state.items)
    .filter(([, v]) => v.taxed != null)
    .map(([code, v]) => ({ supplier_code: code, taxed: !!v.taxed, item_name: v.name || null, invoices_seen: v.seen || 1 }));
  log(`رفع ${rows.length} صنف للقاعدة…`);
  let done = 0;
  for (let i = 0; i < rows.length; i += 300) {
    const r = await fetch(`${CFG.supabaseUrl}/rest/v1/rpc/ibnsina_tax_upsert`, {
      method: 'POST',
      headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + CFG.anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_key: CFG.syncKey, p_rows: rows.slice(i, i + 300) })
    });
    const t = await r.text();
    if (!r.ok) { console.error('فشل الرفع: ' + t.slice(0, 200)); process.exit(1); }
    done += Number(t) || 0;
    if (i + 300 < rows.length) await sleep(300);
  }
  log(`✓ اتسجّل ${done} صنف في ibnsina_tax`);
}

(async () => {
  const state = load();
  if (has('--report')) return report(state);
  if (has('--push')) { await push(state); return report(state); }
  const ctx = await login();
  const n = num('--n', 0);
  /* --daily: التشغيل المجدول. بيلقط الفواتير الجديدة بس ويرفعها،
     من غير --classify لأن التصنيف اتقاس (2026-10-01) وطلع بيحسم 9%
     بس من الأصناف — نداءات من غير عائد. */
  if (has('--daily')) {
    await pullInvoices(ctx, state, num('--n', 200), true);
    save(state);
    await push(state);
    return report(state);
  }
  if (n) await pullInvoices(ctx, state, n);
  if (n || has('--classify')) await classify(ctx, state);
  save(state);
  report(state);
})();
