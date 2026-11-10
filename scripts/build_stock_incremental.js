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

   ── فخاخ متحسّب لها ──
   · البحث بالكود **جزئي مش مطابق**: "7220" بيرجّع 33 صف فيهم 57220
     و72200. فبنفلتر الرد على الكود بالحرف.
   · الأكواد ≤3 حروف (564 صنف) بحثها بيرجّع آلاف الصفوف — بنستثنيها،
     ومعظمها خدمات بلا رصيد (قياس ضغط، توصيل، تحضير). اللقطة الكاملة
     بالليل بتغطّيها.
   · الـAPI بترجّع HTTP 200 وهي فاشلة بغلاف {"Message":"Fail"} —
     بنفحص الغلاف وإلا الفشل بيبان «يوم من غير حركة».
   · «Using Fields Below» بتبعت الأرقام كنصوص والـAPI بتنهار — لازم
     «Using JSON». وhttps مباشرة لأن http بيرد بتحويلة 301. */

const fs = require('fs');
const path = require('path');

const SB_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const EPLUS  = 'https://eplus.ebrahimhamdy.com/api/Item/SearchItem';
const CRED   = { id: 'uJYS75ZTBXnlYIqg', name: 'eplus' };
const HOURS  = 2;      // نافذة أوسع من الفترة عشان الجولة الفاشلة تتلحق
const MINLEN = 4;      // أقصر كود نقبل نبحث بيه
const MAXCODES = 800;  // حارس: فوق كده يبقى في حاجة غلط
const CHUNK  = 2000;

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
let short = 0;
for (const r of rows) {
  if (!r || r.itm_code === undefined || r.itm_code === null) continue;
  if (STORES.indexOf(r.sto_name) < 0) continue;
  const c = String(r.itm_code).trim();
  if (!c) continue;
  // البحث بالكود جزئي: كود قصير بيرجّع آلاف الصفوف. اللقطة الليلية تغطّيه.
  if (c.length < MINLEN) { short++; continue; }
  codes.add(c);
}

if (codes.size > MAXCODES) {
  throw new Error('عدد الأكواد ' + codes.size + ' فوق الحد — راجع النافذة');
}
// مفيش تغيير أصلًا = جولة شرعية (ساعة هادية). مش خطأ.
return [...codes].map(c => ({ json: { code: c, total: codes.size, short: short } }));
`.trim();

/* ── كود عقدة «تقسيم» ─────────────────────────────────────────────── */
const codeSplit = `
// الفروع المفتوحة للكتابة. وسّع السطر ده بعد التحقق:
//   const BRANCHES_ON = ['mamora','san','bishr','seyouf'];
const BRANCHES_ON = ['mamora'];

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

const nodes = [
  {
    parameters: { rule: { interval: [{ field: 'hours', hoursInterval: 1 }] } },
    type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.3,
    position: [-1400, 300], name: 'كل ساعة',
  },
  /* النافذة ساعتين والجولة كل ساعة: الجولة اللي بعدها بتلحق اللي فاتت
     لو وقعت. والوقت قاهرة صراحةً — السيرفر UTC والفرق ساعتين. */
  eplusNode('تغيّرات',
    "={{ JSON.stringify({ itm_lasttrans_date_search: $now.plus({hour:-" + HOURS + "}).format('yyyy-MM-dd HH:mm:ss') }) }}",
    [-1180, 300]),
  {
    parameters: { jsCode: codeCodes },
    type: 'n8n-nodes-base.code', typeVersion: 2,
    position: [-960, 300], name: 'أكواد',
  },
  /* نداء خفيف لكل كود، واحد في المرة بثانية راحة. ده عكس صفحات اللقطة
     الكاملة اللي بتخلّي الـAPI تمسح الكتالوج كله في كل نداء. */
  eplusNode('رصيد', '={{ JSON.stringify({ itm_code_search: $json.code }) }}',
    [-740, 300], { batching: { batch: { batchSize: 1, batchInterval: 1000 } } }),
  {
    parameters: { jsCode: codeSplit },
    type: 'n8n-nodes-base.code', typeVersion: 2,
    position: [-520, 300], name: 'تقسيم',
  },
  {
    parameters: {
      method: 'POST', url: SB_URL + '/rest/v1/rpc/upsert_branch_stock',
      sendHeaders: true,
      headerParameters: { parameters: [
        { name: 'apikey',        value: '={{ $env.SUPABASE_SERVICE_KEY }}' },
        { name: 'Authorization', value: '=Bearer {{ $env.SUPABASE_SERVICE_KEY }}' },
      ] },
      sendBody: true, specifyBody: 'json',
      jsonBody: '={{ JSON.stringify($json) }}',
      options: { timeout: 120000 },
    },
    type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [-300, 300], name: 'كتابة',
    ...httpCommon,
  },
];

const connections = {
  'كل ساعة': { main: [[{ node: 'تغيّرات', type: 'main', index: 0 }]] },
  'تغيّرات': { main: [[{ node: 'أكواد',   type: 'main', index: 0 }]] },
  'أكواد':   { main: [[{ node: 'رصيد',    type: 'main', index: 0 }]] },
  'رصيد':    { main: [[{ node: 'تقسيم',   type: 'main', index: 0 }]] },
  'تقسيم':   { main: [[{ node: 'كتابة',   type: 'main', index: 0 }]] },
};

const wf = { name: 'المخزون — فرقي بالكود', nodes, connections, pinData: {} };
const out = path.join(__dirname, '..', 'docs', 'n8n_stock_incremental.json');
fs.writeFileSync(out, JSON.stringify(wf, null, 2), 'utf8');

const back = JSON.parse(fs.readFileSync(out, 'utf8'));
let bad = 0;
for (const n of back.nodes) {
  if (n.type === 'n8n-nodes-base.code') {
    try { new Function(n.parameters.jsCode); }
    catch (e) { console.log('✗ كود «' + n.name + '»: ' + e.message); bad++; }
  }
  if (n.parameters && n.parameters.url === EPLUS && n.parameters.specifyBody !== 'json') {
    console.log('✗ «' + n.name + '» مش Using JSON'); bad++;
  }
}
const names = new Set(back.nodes.map(n => n.name));
for (const [from, c] of Object.entries(back.connections)) {
  if (!names.has(from)) { console.log('✗ وصلة من ' + from); bad++; }
  for (const t of c.main[0]) if (!names.has(t.node)) { console.log('✗ وصلة لـ' + t.node); bad++; }
}
if (/eyJ|service_role|password/i.test(JSON.stringify(back))) { console.log('✗ فيه سر'); bad++; }
console.log(bad ? '✗ فشل ' + bad
  : '✅ ' + back.nodes.length + ' عقد · JSON صالح · الكود بيتحلّل · Using JSON · مفيش أسرار');
console.log('الملف: ' + out);
