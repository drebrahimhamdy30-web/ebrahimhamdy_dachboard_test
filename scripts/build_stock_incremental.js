/* يبني وركفلو n8n للمزامنة الفرقية: الفلتر يقول **مين** اتغيّر،
   والبحث بالكود يجيب **الرصيد الصح**.
   التشغيل:  node scripts/build_stock_incremental.js
   الناتج :  docs/n8n_stock_incremental.json

   ── ليه ده مختلف عن اللقطة الكاملة ──
   اللقطة بتطلب صفحات من 69,641 صف، وكل صفحة بتخلّي الـAPI **تمسح
   الكتالوج كله** وتتخطّى وتاخد — فالنداء تقيل، و13 منهم ورا بعض
   بيوقّعوا الاتصال (aborted) وقت الشغل. والبحث بكود واحد **لمسة
   مفهرسة** بترجع في لحظة. فـ~150 نداء خفيف أأمن من 13 تقيل.

   ── الفلتر صالح لحاجة واحدة بس ──
   `itm_lasttrans_date_search` بيرجّع **كمية الدفعات اللي اتحركت في
   النافذة** مش رصيد الصنف (مثبت على كود 7220: مع الفلتر 1، من غيره
   65). فبناخد منه **قايمة الأكواد** ونرمي الكميات، وبعدين نجيب الرصيد
   الحقيقي بنداء بلا فلتر تاريخ.
   ودقّة الفلتر في معرفة «مين اتغيّر» اتأكدت على يوم ويومين وأسبوع
   وشهر: **صفر صنف فات**.
   واتأكدت تاني 2026-11-10 على جولة حقيقية: 76 كود، فروقهم كلها
   نقصان بيع (−1 · −0.5 · −3) وزيادة واحدة طلعت استلام + تغيير سعر
   حقيقي (كود 66949، تعديل الصنف 12:34 في نفس اليوم).

   ── النافذة من القاعدة مش من الساعة (2026-11-10) ──
   كانت `$now - N ساعة`، ودي بتسيب فجوة صامتة: جولة وقعت = ساعتها
   مامسحهاش حد لحد اللقطة الليلية. بقت من `stock_sync_window()` اللي
   بتقرا **آخر كتابة ناجحة** من `updated_at` — فالجولة الواقعة
   بتتلحق بالظبط. راجع docs/migrate_202_stock_sync_window.sql.

   ── الأربع فروع مش أربع أضعاف النداءات ──
   نداء البحث بالكود بيرجّع صف الصنف في **كل المخازن** مرة واحدة،
   والأصناف السريعة بتتحرك في الفروع كلها — فاتحاد الأكواد بيزيد
   ~2–3 أضعاف مش 4، ونفس النداء بيخدم الأربعة.

   ── فخاخ متحسّب لها ──
   · البحث بالكود **جزئي مش مطابق**: "7220" بيرجّع 33 صف فيهم 57220
     و72200. فبنفلتر الرد على الكود بالحرف.
   · الأكواد ≤3 حروف (564 صنف) بحثها بيرجّع آلاف الصفوف — بنستثنيها،
     ومعظمها خدمات بلا رصيد (قياس ضغط، توصيل، تحضير). اللقطة الكاملة
     بالليل بتغطّيها.
   · الـAPI بترجّع HTTP 200 وهي فاشلة بغلاف {"Message":"Fail"} —
     بنفحص الغلاف وإلا الفشل بيبان «يوم من غير حركة».
   · «Using Fields Below» بتبعت الأرقام كنصوص والـAPI بتنهار — لازم
     «Using JSON». وhttps مباشرة لأن http بيرد بتحويلة 301.
   · لو تاريخ النافذة ضاع، الـbody بيبقى {} والـAPI بترجّع **الكتالوج
     كله** — يعني بالظبط النداء التقيل اللي بنهرب منه. فعقدة «تحقق»
     بتوقف الجولة **قبل** النداء مش بعده.
   · الفرع اللي لسه على الوركفلو القديم (استبدال الجدول) بيدوس على أي
     كتابة فرقية عند الـswap — فالقديم يتقفل مع فتح الفرع هنا. */

const fs = require('fs');
const path = require('path');

const SB_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const EPLUS  = 'https://eplus.ebrahimhamdy.com/api/Item/SearchItem';
const CRED   = { id: 'uJYS75ZTBXnlYIqg', name: 'eplus' };

/* مصدر واحد للفروع المفتوحة — بيتحطّ في «نافذة» و«تقسيم» مع بعض،
   عشان ما يحصلش انحراف بين اللي بنحسب نافذته واللي بنكتبه.
   وسّعه بعد التحقق:  ['mamora','san','bishr','seyouf']  */
const BRANCHES = ['mamora'];

const OVERLAP  = 10;    // دقايق تغطية راجعة — الجولة بتاخد وقت بين الجلب والكتابة
const MAXHOURS = 6;     // سقف النافذة؛ فوقه capped واللقطة الليلية هي الحل
const MINLEN   = 4;     // أقصر كود نقبل نبحث بيه
const MAXCODES = 1500;  // حارس: فوق كده الجولة هتتعدّى على اللي بعدها
const CHUNK    = 2000;

/* ── كود عقدة «تحقق» ──────────────────────────────────────────────── */
const codeGuard = `
const w = $json || {};
// بلا تاريخ النافذة الـAPI بترجّع الكتالوج كله. نوقف قبل النداء مش بعده.
if (!w.since_cairo || !/^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$/.test(w.since_cairo)) {
  throw new Error('نافذة المزامنة مش صالحة: ' + JSON.stringify(w).slice(0, 300));
}
const notes = [];
// capped = المزامنة كانت واقفة أطول من السقف، فالنافذة مابتغطّيش الفجوة كلها
if (w.capped) notes.push('النافذة اتقصّت عند ${MAXHOURS} ساعة — اللقطة الكاملة لازمة');
if (w.cold)   notes.push('فرع من غير أي ختم كتابة — بداية بارد');
if (notes.length) console.log(notes.join(' · '));
return [{ json: { since: w.since_cairo, gap_minutes: w.gap_minutes,
                  capped: !!w.capped, cold: !!w.cold,
                  oldest: w.oldest || null, notes: notes } }];
`.trim();

/* ── كود عقدة «أكواد» ─────────────────────────────────────────────── */
const codeCodes = `
const MINLEN = ${MINLEN}, MAXCODES = ${MAXCODES};

// مخازن فروعنا — الرد بيرجّع مخازن تانية (طوسون، سندره، العجز) مش بتاعتنا
const STORES = ['الصيدلية', 'ابراهيم حمدي 2', 'ابراهيم حمدي 3', 'السيوف'];

const o = $('تغيّرات').first().json;
if (o.Error || String(o.Message).toLowerCase() === 'fail') {
  throw new Error('eplus رفض نداء التغيّرات: ' + (o.Error || o.Message));
}
const rows = o.Data || [];

// ⚠️ الكميات في الرد ده **ناقصة** (بتاعة الدفعات اللي اتحركت بس).
//    إحنا عايزين الأكواد لا غير.
const codes = new Set();
let short = 0, other = 0;
for (const r of rows) {
  if (!r || r.itm_code === undefined || r.itm_code === null) continue;
  if (STORES.indexOf(r.sto_name) < 0) { other++; continue; }
  const c = String(r.itm_code).trim();
  if (!c) continue;
  // البحث بالكود جزئي: كود قصير بيرجّع آلاف الصفوف. اللقطة الليلية تغطّيه.
  if (c.length < MINLEN) { short++; continue; }
  codes.add(c);
}

if (codes.size > MAXCODES) {
  throw new Error('عدد الأكواد ' + codes.size + ' فوق الحد ' + MAXCODES +
    ' — الجولة دي هتتعدّى على اللي بعدها، شغّل اللقطة الكاملة');
}
// مفيش تغيير أصلًا = جولة شرعية (ساعة هادية). مش خطأ.
console.log('نافذة ' + $('تحقق').first().json.gap_minutes + 'د · ' + rows.length +
  ' صف · ' + codes.size + ' كود · قصير ' + short + ' · مخازن تانية ' + other);
return [...codes].map(c => ({ json: { code: c, total: codes.size, short: short } }));
`.trim();

/* ── كود عقدة «تقسيم» ─────────────────────────────────────────────── */
const codeSplit = `
// الفروع المفتوحة للكتابة — نفس قايمة «نافذة» (مصدر واحد في البانى)
const BRANCHES_ON = ${JSON.stringify(BRANCHES)};

const BR = {
  'الصيدلية':        'mamora',
  'ابراهيم حمدي 2':  'san',
  'ابراهيم حمدي 3':  'bishr',
  'السيوف':          'seyouf',
};

// الأكواد اللي طلبناها — عشان نفلتر الرد الجزئي على الكود بالحرف
const asked = new Set($('أكواد').all().map(i => String(i.json.code)));

const map = new Map();   // مفتاح فرع|كود
let seen = 0, stray = 0;
for (const it of $('رصيد').all()) {
  const o = it.json;
  if (o.Error || String(o.Message).toLowerCase() === 'fail') {
    throw new Error('eplus رفض بحث كود: ' + (o.Error || o.Message));
  }
  for (const r of (o.Data || [])) {
    seen++;
    const code = String((r && r.itm_code) ?? '');
    // ⚠️ البحث جزئي: "7220" بيرجّع 57220 و72200 كمان. بناخد المطابق بس.
    if (!asked.has(code)) { stray++; continue; }
    const br = BR[r.sto_name];
    if (!br || BRANCHES_ON.indexOf(br) < 0) continue;
    map.set(br + '|' + code, r);
  }
}

if (map.size === 0) {
  throw new Error('ولا صف مطابق من ' + seen + ' صف رجعوا — راجع الفلترة');
}

const byBranch = {};
for (const [k, r] of map) {
  const br = k.split('|')[0];
  (byBranch[br] = byBranch[br] || []).push(r);
}

console.log('رجع ' + seen + ' صف · مطابق ' + map.size + ' · مرفوض ' + stray +
  ' · ' + Object.keys(byBranch).map(b => b + '=' + byBranch[b].length).join(' '));

const out = [];
for (const br of Object.keys(byBranch)) {
  const list = byBranch[br];
  for (let i = 0; i < list.length; i += ${CHUNK}) {
    out.push({ json: { p_branch: br, p_rows: list.slice(i, i + ${CHUNK}) } });
  }
}
return out;
`.trim();

/* ── العقد ────────────────────────────────────────────────────────── */
const httpCommon = { retryOnFail: true, maxTries: 5, waitBetweenTries: 15000 };

const sbHeaders = { parameters: [
  { name: 'apikey',        value: '={{ $env.SUPABASE_SERVICE_KEY }}' },
  { name: 'Authorization', value: '=Bearer {{ $env.SUPABASE_SERVICE_KEY }}' },
] };

const sbNode = (name, fn, jsonBody, pos) => ({
  parameters: {
    method: 'POST', url: SB_URL + '/rest/v1/rpc/' + fn,
    sendHeaders: true, headerParameters: sbHeaders,
    sendBody: true, specifyBody: 'json', jsonBody,
    options: { timeout: 120000 },
  },
  type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
  position: pos, name, ...httpCommon,
});

const eplusNode = (name, jsonBody, pos, extraOptions) => ({
  parameters: {
    method: 'PATCH', url: EPLUS,
    authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth',
    sendBody: true,
    /* لازم Using JSON — Fields Below بتبعت الأرقام كنصوص والـAPI بتنهار */
    specifyBody: 'json', jsonBody,
    options: Object.assign({ timeout: 120000 }, extraOptions || {}),
  },
  type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
  position: pos, name,
  credentials: { httpBasicAuth: CRED },
  ...httpCommon,
});

const codeNode = (name, jsCode, pos) => ({
  parameters: { jsCode },
  type: 'n8n-nodes-base.code', typeVersion: 2,
  position: pos, name,
});

const nodes = [
  {
    parameters: { rule: { interval: [{ field: 'hours', hoursInterval: 1 }] } },
    type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.3,
    position: [-1620, 300], name: 'كل ساعة',
  },
  /* النافذة من آخر كتابة ناجحة في جداول الفروع المفتوحة — مش من الساعة.
     بترجّع التاريخ جاهز بتوقيت القاهرة naive زي ما eplus عايزه، فمفيش
     تحويل توقيت في n8n أصلًا (السيرفر UTC والفرق بيتغيّر مع DST). */
  sbNode('نافذة', 'stock_sync_window',
    '={{ JSON.stringify({ p_branches: ' + JSON.stringify(BRANCHES) +
      ', p_overlap_minutes: ' + OVERLAP + ', p_max_hours: ' + MAXHOURS + ' }) }}',
    [-1400, 300]),
  codeNode('تحقق', codeGuard, [-1180, 300]),
  eplusNode('تغيّرات',
    '={{ JSON.stringify({ itm_lasttrans_date_search: $json.since }) }}',
    [-960, 300]),
  codeNode('أكواد', codeCodes, [-740, 300]),
  /* نداء خفيف لكل كود، واحد في المرة بثانية راحة. ده عكس صفحات اللقطة
     الكاملة اللي بتخلّي الـAPI تمسح الكتالوج كله في كل نداء. */
  eplusNode('رصيد', '={{ JSON.stringify({ itm_code_search: $json.code }) }}',
    [-520, 300], { batching: { batch: { batchSize: 1, batchInterval: 1000 } } }),
  codeNode('تقسيم', codeSplit, [-300, 300]),
  sbNode('كتابة', 'upsert_branch_stock', '={{ JSON.stringify($json) }}', [-80, 300]),
];

const order = ['كل ساعة', 'نافذة', 'تحقق', 'تغيّرات', 'أكواد', 'رصيد', 'تقسيم', 'كتابة'];
const connections = {};
for (let i = 0; i < order.length - 1; i++) {
  connections[order[i]] = { main: [[{ node: order[i + 1], type: 'main', index: 0 }]] };
}

const wf = { name: 'المخزون — فرقي بالكود', nodes, connections, pinData: {} };
const out = path.join(__dirname, '..', 'docs', 'n8n_stock_incremental.json');
fs.writeFileSync(out, JSON.stringify(wf, null, 2), 'utf8');

/* ── فحص الناتج ───────────────────────────────────────────────────── */
const back = JSON.parse(fs.readFileSync(out, 'utf8'));
let bad = 0;
const names = new Set(back.nodes.map(n => n.name));
for (const n of back.nodes) {
  if (n.type === 'n8n-nodes-base.code') {
    try { new Function(n.parameters.jsCode); }
    catch (e) { console.log('x كود «' + n.name + '»: ' + e.message); bad++; }
    /* كل $('اسم') جوّه الكود لازم يكون عقدة موجودة — غلطة الاسم
       بترجع في n8n كرسالة مضللة «العقدة ماتنفّذتش». */
    for (const m of n.parameters.jsCode.matchAll(/\$\('([^']+)'\)/g)) {
      if (!names.has(m[1])) { console.log('x «' + n.name + '» بينادي عقدة مش موجودة: ' + m[1]); bad++; }
    }
  }
  if (n.parameters && n.parameters.url === EPLUS && n.parameters.specifyBody !== 'json') {
    console.log('x «' + n.name + '» مش Using JSON'); bad++;
  }
}
for (const [from, c] of Object.entries(back.connections)) {
  if (!names.has(from)) { console.log('x وصلة من ' + from); bad++; }
  for (const t of c.main[0]) if (!names.has(t.node)) { console.log('x وصلة لـ' + t.node); bad++; }
}
/* قايمة الفروع لازم تكون واحدة في «نافذة» و«تقسيم» */
const wNode = back.nodes.find(n => n.name === 'نافذة');
const sNode = back.nodes.find(n => n.name === 'تقسيم');
for (const b of BRANCHES) {
  if (!wNode.parameters.jsonBody.includes('"' + b + '"')) { console.log('x ' + b + ' مش في «نافذة»'); bad++; }
  if (!sNode.parameters.jsCode.includes('"' + b + '"'))   { console.log('x ' + b + ' مش في «تقسيم»'); bad++; }
}
if (/eyJ|service_role|password/i.test(JSON.stringify(back))) { console.log('x فيه سر'); bad++; }
console.log(bad ? 'x فشل ' + bad
  : 'OK ' + back.nodes.length + ' عقد · JSON صالح · الكود بيتحلّل · مراجع العقد موجودة · '
    + 'Using JSON · الفروع متطابقة (' + BRANCHES.join(',') + ') · مفيش أسرار');
console.log('الملف: ' + out);
