#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   نقل الرابط والمفتاح من جوّه كود العقد لمتغيّرات بيئة
   ═══════════════════════════════════════════════════════════════════
   المشكلة: «sync customers balances -> supabase» فيها ٤ عقد Code
   (فرع لكل واحدة) والرابط والمفتاح مكتوبين بالإيد جوّه الكود. يعني
   يوم التحويل ٨ تعديلات يدوية، وأي واحدة تتنسي = فرع واحد بس يفضل
   يكتب في السحابة المتجمّدة — وده أصعب شكل للخطأ لأنه جزئي وصامت.

   الحل: الكود يقرا من $env، والقيم تتحط في docker-compose. النهاردة
   القيم = قيم السحابة فالسلوك مايتغيّرش. يوم التحويل: متغيّرين
   وإعادة تشغيل.

   🔒 نفس ضمانة أدوات الجرد: **مافيش أي كود ولا أي سر بيتطبع**.
      الخرج أعداد استبدالات بس.

   الاستعمال — من n8n-envify.sh، مش مباشرة.
   ═══════════════════════════════════════════════════════════════════ */
'use strict';
const fs = require('fs');

const CLOUD_REF = 'rxtjoqulmgkkcohmgzgi';
const V_URL = '$env.SUPABASE_URL';
const V_KEY = '$env.SUPABASE_SERVICE_KEY';

const [inFile, outFile, wfFilter] = process.argv.slice(2);
if (!inFile || !outFile) {
  console.error('الاستعمال: node n8n-envify.js <تصدير> <ناتج> [فلتر اسم الورك فلو]');
  process.exit(1);
}

let wfs = JSON.parse(fs.readFileSync(inFile, 'utf8'));
if (!Array.isArray(wfs)) wfs = [wfs];

/* ── التحويل ──────────────────────────────────────────────────────
   قاعدتين بس، ومحدودتين عمدًا في نصوص بين علامتَي تنصيص — عشان
   مانلمسش أي حاجة تانية في الكود:

     'https://<سحابة>.supabase.co'            → $env.SUPABASE_URL
     'https://<سحابة>.supabase.co/rest/v1/x'  → $env.SUPABASE_URL + '/rest/v1/x'
     'eyJ…'  (مفتاح)                          → $env.SUPABASE_SERVICE_KEY

   أي حاجة غير كده مابتتلمسش. */

const Q = "['\"`]";
const reUrl = new RegExp(Q + '(https?://[^\'"`\\s]*' + CLOUD_REF + '[^\'"`\\s]*)' + Q, 'g');
const reKey = new RegExp(Q + '(eyJ[A-Za-z0-9._-]{40,})' + Q, 'g');

function envify(code) {
  let nUrl = 0, nKey = 0;
  let s = code.replace(reUrl, (_m, url) => {
    nUrl++;
    const i = url.indexOf('.supabase.co');
    const path = i >= 0 ? url.slice(i + '.supabase.co'.length) : '';
    return path ? V_URL + " + '" + path + "'" : V_URL;
  });
  s = s.replace(reKey, () => { nKey++; return V_KEY; });
  return { code: s, nUrl, nKey };
}

/* ── التنفيذ ─────────────────────────────────────────────────────── */

const report = [];
let touchedWfs = 0, totalUrl = 0, totalKey = 0;
const picked = [];

for (const wf of wfs) {
  if (wfFilter && !String(wf.name || '').includes(wfFilter)) continue;
  const nodes = Array.isArray(wf.nodes) ? wf.nodes : [];
  let wfTouched = false;

  for (const n of nodes) {
    const p = n.parameters || {};
    // بنلمس خانات الكود بس
    for (const field of ['jsCode', 'pythonCode', 'code']) {
      if (typeof p[field] !== 'string') continue;
      const r = envify(p[field]);
      if (!r.nUrl && !r.nKey) continue;
      p[field] = r.code;
      wfTouched = true;
      totalUrl += r.nUrl; totalKey += r.nKey;
      report.push({ wf: wf.name, node: n.name || '(بلا اسم)', url: r.nUrl, key: r.nKey });
    }
  }
  if (wfTouched) { touchedWfs++; picked.push(wf); }
}

/* ── فحص أمان: مافيش أي أثر للسحابة فضل في اللي عدّلناه ─────────── */
const leftovers = [];
for (const wf of picked) {
  for (const n of (wf.nodes || [])) {
    const p = n.parameters || {};
    for (const field of ['jsCode', 'pythonCode', 'code']) {
      if (typeof p[field] !== 'string') continue;
      if (p[field].includes(CLOUD_REF)) leftovers.push((wf.name || '?') + ' → ' + (n.name || '?') + ' (رابط)');
      if (/eyJ[A-Za-z0-9._-]{40,}/.test(p[field])) leftovers.push((wf.name || '?') + ' → ' + (n.name || '?') + ' (مفتاح)');
    }
  }
}

/* ── العرض — أعداد بس، صفر كود وصفر أسرار ───────────────────────── */
const bold = s => '\u001b[1m' + s + '\u001b[0m';

console.log('');
if (!report.length) {
  console.log('  مفيش أي عقدة فيها رابط أو مفتاح مكتوب في الكود' +
              (wfFilter ? ' (بالفلتر «' + wfFilter + '»)' : ''));
  console.log('  يا إما اتعملت قبل كده، يا إما الفلتر مش مطابق.');
  process.exit(3);
}
console.log(bold('══ اللي هيتغيّر ══'));
let lastWf = null;
for (const r of report) {
  if (r.wf !== lastWf) { console.log('  ' + bold(r.wf)); lastWf = r.wf; }
  const bits = [];
  if (r.url) bits.push(r.url + ' رابط');
  if (r.key) bits.push(r.key + ' مفتاح');
  console.log('      • ' + r.node + '   ← ' + bits.join(' · '));
}
console.log('');
console.log('  الإجمالي: ' + bold(String(totalUrl + totalKey)) + ' استبدال في ' +
            report.length + ' عقدة · ' + touchedWfs + ' ورك فلو');
console.log('  الرابط  → ' + V_URL);
console.log('  المفتاح → ' + V_KEY);

if (leftovers.length) {
  console.log('');
  console.log(bold('🔴 وقفنا — فضل أثر للسحابة بعد التحويل:'));
  for (const l of leftovers) console.log('      • ' + l);
  console.log('  مكتبناش أي ملف. شوف الكود بإيدك — غالبًا الرابط متبني');
  console.log('  بطريقة تانية (تجزئة أو تركيب) فالقاعدتين ماشافوهوش.');
  process.exit(2);
}

fs.writeFileSync(outFile, JSON.stringify(picked, null, 2));
console.log('');
console.log('  ✓ الناتج اتكتب (الورك فلوز المتأثرة بس: ' + picked.length + ')');
