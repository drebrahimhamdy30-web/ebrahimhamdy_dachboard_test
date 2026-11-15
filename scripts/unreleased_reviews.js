/* unreleased_reviews.js — حركات اتعمل عليها «تم» بمدفوع > 0 و**ما اتصرفتش**.
 *
 * **قراءة فقط.** مابيكتبش ولا صف.
 *
 * الصرف الحقيقي بيتسجّل في `wallet_disbursement_queue` بحالة `done`.
 * أي مراجعة بمدفوع > 0 مالهاش صف done = فلوس اتقفل عليها في الشاشة
 * ومحدش حوّلها في eplus.
 *
 * ⚠️ الصرف التلقائي مفعّل على **المعمورة بس** (DISBURSE_BRANCHES في
 *    current_shift.html). فباقي الفروع كل مراجعاتها هتطلع هنا — ده
 *    متوقَّع مش عطل، والسكربت بيفصلهم في عمود «الحالة».
 *
 * التشغيل:
 *   node scripts/unreleased_reviews.js --from "2026-11-14 09:00" [--branch=mamora] [--csv=out.csv]
 *   (--from بتوقيت القاهرة؛ الافتراضي أول النهاردة)
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
const BRANCH = val('branch', '');
const CSV    = val('csv', '');

/* الأوفست بيتحسب من المنطقة الزمنية مش ثابت — الترقيع بـ+2 بيقع مع
   التوقيت الصيفي. نفس الطريقة المستعملة في verify_stock_vs_report.js */
function cairoToUtc(s) {
  const m = String(s).trim().match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?$/);
  if (!m) throw new Error('صيغة --from لازم تكون "YYYY-MM-DD HH:MM" — جالي: ' + s);
  const [, Y, Mo, D, H, Mi] = m;
  const guess = Date.UTC(+Y, +Mo - 1, +D, +(H || 0), +(Mi || 0));
  const f = new Intl.DateTimeFormat('en-US', { timeZone: 'Africa/Cairo', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const p = Object.fromEntries(f.formatToParts(new Date(guess)).filter(x => x.type !== 'literal').map(x => [x.type, +x.value]));
  const shown = Date.UTC(p.year, p.month - 1, p.day, p.hour === 24 ? 0 : p.hour, p.minute, p.second);
  return new Date(guess - (shown - guess));
}
const todayCairo = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Africa/Cairo' });
const FROM = cairoToUtc(val('from', todayCairo() + ' 00:00'));

const cfg = JSON.parse(fs.readFileSync(path.join(process.env.USERPROFILE, '.phalix', 'sync_engine.json'), 'utf8').replace(/^﻿/, ''));
const H = { apikey: cfg.serviceKey, Authorization: 'Bearer ' + cfg.serviceKey };

async function getAll(pathq) {
  const out = []; let from = 0; const step = 1000;
  for (;;) {
    const sep = pathq.includes('?') ? '&' : '?';
    const r = await fetch(`${cfg.supabaseUrl}/rest/v1/${pathq}${sep}limit=${step}&offset=${from}`, { headers: H });
    if (!r.ok) throw new Error('GET ' + pathq + ' → ' + r.status + ' ' + await r.text());
    const page = await r.json();
    out.push(...page);
    if (page.length < step) break;
    from += step;
  }
  return out;
}
const cairo = s => s ? new Date(s).toLocaleString('sv-SE', { timeZone: 'Africa/Cairo' }).slice(5, 16) : '—';
const eg = n => Math.round(n).toLocaleString('en-US');
/* ⚠️ الكود ممكن يبقى فيه فاصلة — الاقتباس إلزامي، و`in.()` بيحتاج
   تنصيص على القيم النصية. */
const inList = v => '(' + v.map(x => '"' + String(x).replace(/"/g, '\\"') + '"') + ')';

(async () => {
  const br = BRANCH ? `&branch=eq.${encodeURIComponent(BRANCH)}` : '';
  const revs = (await getAll(
    `shift_txn_reviews?select=branch,fh_id,paid,channel,reviewed_by,reviewed_at`
    + `&reviewed_at=gte.${FROM.toISOString()}&paid=gt.0${br}&order=branch,reviewed_at`));

  if (!revs.length) { console.log('مفيش مراجعات بمدفوع > 0 في المدى ده.'); return; }

  /* الطابور والصور والحركات — بنجيبهم بالمفاتيح اللي معانا بس */
  const ids = [...new Set(revs.map(r => r.fh_id))];
  const q = {}, rc = {}, tx = {};
  for (let i = 0; i < ids.length; i += 200) {
    const part = ids.slice(i, i + 200);
    (await getAll(`wallet_disbursement_queue?select=branch,fh_id,status,eplus_fh_id,error,resolved_to_name`
                  + `&fh_id=in.(${part.join(',')})`)).forEach(x => { q[x.branch + '|' + x.fh_id] = x; });
    (await getAll(`cashier_transactions?select=branch,fh_id,sth_id,actual_date,user_name`
                  + `&fh_id=in.(${part.join(',')})`)).forEach(x => { tx[x.branch + '|' + x.fh_id] = x; });
    (await getAll(`txn_receipts?select=branch,ref_id&kind=eq.card`
                  + `&ref_id=in.${inList(part)}`)).forEach(x => { rc[x.branch + '|' + x.ref_id] = true; });
  }

  const rows = [];
  let done = 0;
  for (const r of revs) {
    const k = r.branch + '|' + r.fh_id;
    const qq = q[k];
    if (qq && qq.status === 'done') { done++; continue; }
    const t = tx[k] || {};
    rows.push({
      branch: r.branch, fh_id: r.fh_id, bill: t.sth_id || '',
      when: cairo(t.actual_date), paid: +r.paid, channel: r.channel || '',
      cashier: t.user_name || '', by: r.reviewed_by || '', at: cairo(r.reviewed_at),
      img: rc[k] ? 'أيوه' : 'لأ',
      status: qq ? qq.status : 'مادخلش الطابور',
      error: (qq && qq.error) || ''
    });
  }

  console.log('من        : ' + cairo(FROM.toISOString()) + ' القاهرة');
  console.log('مراجعات بمدفوع > 0 : ' + revs.length + '   ·   اتصرف: ' + done + '   ·   لم يُصرف: ' + rows.length);
  console.log('');

  const byBr = {};
  rows.forEach(r => { (byBr[r.branch] = byBr[r.branch] || []).push(r); });
  for (const b of Object.keys(byBr)) {
    const list = byBr[b];
    const sum = list.reduce((a, x) => a + x.paid, 0);
    const noImg = list.filter(x => x.img === 'لأ').length;
    console.log('══ ' + b + ' ══  ' + list.length + ' حركة · ' + eg(sum) + ' ج · ' + noImg + ' منهم بلا صورة');
    console.log('  الحركة      الفاتورة   وقت العملية  المدفوع   الحساب          صورة  اللي عمل تم       وقت تم        الحالة');
    list.sort((x, y) => y.paid - x.paid).forEach(x =>
      console.log('  ' + String(x.fh_id).padEnd(12) + String(x.bill).padEnd(10) + x.when.padEnd(13) +
        String(x.paid).padStart(8) + '   ' + String(x.channel).padEnd(16) + x.img.padEnd(6) +
        String(x.by).slice(0, 16).padEnd(18) + x.at.padEnd(14) + x.status +
        (x.error ? ' — ' + x.error.slice(0, 40) : '')));
    console.log('');
  }

  if (CSV) {
    const esc = s => '"' + String(s ?? '').replace(/"/g, '""') + '"';
    const head = ['الفرع','رقم الحركة','رقم الفاتورة','وقت العملية','المدفوع','الحساب','الكاشير','فيه صورة','اللي عمل تم','وقت تم','حالة الصرف','الخطأ'];
    const lines = [head.join(',')];
    rows.forEach(x => lines.push([x.branch, x.fh_id, x.bill, x.when, x.paid, x.channel,
      x.cashier, x.img, x.by, x.at, x.status, x.error].map(esc).join(',')));
    fs.writeFileSync(CSV, '﻿' + lines.join('\r\n'), 'utf8');   // BOM عشان إكسل يقرا العربي
    console.log('الملف: ' + CSV);
  }
})().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
