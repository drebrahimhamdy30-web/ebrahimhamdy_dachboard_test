/* يبني وركفلو n8n لمزامنة المخزون — **لقطة كاملة بالصفحات، للأربع فروع**.
   التشغيل:  node scripts/build_stock_workflow.js
   الناتج :  docs/n8n_stock_sync.json

   ── ليه سكربت مش ملف JSON مكتوب بالإيد ──
   كود عقد n8n بيتخزّن كنص داخل JSON، فالكتابة اليدوية معناها هروب أسطر
   وعلامات تنصيص بالإيد، وأول غلطة بتبوّظ الملف من غير ما تبان. هنا الكود
   مكتوب طبيعي وJSON.stringify بيتولّى الهروب، والسكربت بيفحص الناتج.

   ── ليه اللقطة الكاملة وليس الفلتر الفرقي (قرار 2026-11-10) ──
   `itm_lasttrans_date_search` بيرجّع **كمية الدفعات اللي اتحركت في
   النافذة**، مش رصيد الصنف. مثبت داخل الـAPI نفسها على كود 7220 في نفس
   اللحظة: مع الفلتر **1**، من غير الفلتر **65**. فالفلتر صالح لمعرفة
   «مين اتغيّر» بس — والكمية اللي معاه لا تصلح للكتابة.

   ── وليه الترقيم بقى شغّال ──
   «Using Fields Below» بتبعت الأرقام **كنصوص** (`"page_no": "2"`)
   والـAPI بتنهار معاها بـaborted. «Using JSON» بتبعتها أرقام حقيقية
   فتشتغل. ودي كانت سبب كل الـaborted في الترقيم، مش كلاودفلير.

   ── وليه آخر صفحة محسوبة ──
   الـAPI بتعمل GetRange بالحجم المطلوب من غير ما تقصّه على الباقي، فلو
   طلبت 1000 والباقي 641 بترجّع استثناء .NET. الحل: حجم آخر صفحة يتحسب
   من `AllRecords` اللي الرد نفسه بيرجّعه. */

const fs = require('fs');
const path = require('path');

const SB_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const EPLUS  = 'http://eplus.ebrahimhamdy.com/api/Item/SearchItem';
const CRED   = { id: 'uJYS75ZTBXnlYIqg', name: 'eplus' };
const PAGE   = 1000;   // حجم الصفحة
const CHUNK  = 2000;   // أقصى صفوف في نداء كتابة واحد

/* ── كود عقدة «صفحات» ─────────────────────────────────────────────── */
const codePages = `
const PAGE = ${PAGE};

// ⚠️ eplus بيرجّع HTTP 200 حتى وهو فاشل، بغلاف
//    {"Message":"Fail","Error":"...","Data":[]}. من غير الفحص ده الفشل
//    بيبان «يوم من غير حركة» — نجاح كاذب.
const o = $('عدّ').first().json;
if (o.Error || String(o.Message).toLowerCase() === 'fail') {
  throw new Error('eplus رفض نداء العدّ: ' + (o.Error || o.Message));
}

const total = Number(o.AllRecords || 0);
if (!total) throw new Error('AllRecords رجع فاضي — مافيش عدد نبني عليه');
if (total > 500000) throw new Error('AllRecords رقم غير معقول: ' + total);

// آخر صفحة حجمها = الباقي بالظبط. لو طلبنا 1000 والباقي 641 الـAPI
// بترمي «Offset and length were out of bounds».
const pages = [];
for (let off = 0; off < total; off += PAGE) {
  pages.push({ json: {
    no:    Math.floor(off / PAGE) + 1,
    size:  Math.min(PAGE, total - off),
    total: total,
  }});
}
return pages;
`.trim();

/* ── كود عقدة «تقسيم» ─────────────────────────────────────────────── */
const codeSplit = `
// الفروع المفتوحة للكتابة. بنبدأ بالمعمورة لوحدها والتلاتة التانيين
// على وركفلوهاتهم القديمة. بعد التحقق نوسّع السطر ده — **من غير أي
// وركفلو جديد** — ونقفل القدام:
//   const BRANCHES_ON = ['mamora','san','bishr','seyouf'];
const BRANCHES_ON = ['mamora'];

// نداء واحد بيرجّع الأربع فروع. خريطة المخزن ← الفرع، نفس أسماء
// branches.aliases في القاعدة (والدالة بتفلتر بيها كمان كطبقة تانية).
const BR = {
  'الصيدلية':        'mamora',
  'ابراهيم حمدي 2':  'san',
  'ابراهيم حمدي 3':  'bishr',
  'السيوف':          'seyouf',
};

const pages = $('جلب').all().map(i => i.json);
let rows = [];
for (const p of pages) {
  if (p.Error || String(p.Message).toLowerCase() === 'fail') {
    throw new Error('eplus رفض صفحة: ' + (p.Error || p.Message));
  }
  rows = rows.concat(p.Data || []);
}

// حارس الاكتمال: لو صفحة رجعت ناقصة بالساكت، نوقف قبل ما نكتب.
// (الكتابة upsert فمفيش خطر حذف، بس الفشل الواضح أحسن من الناقص الصامت.)
const expected = Number($('صفحات').first().json.total || 0);
if (expected && rows.length < expected * 0.95) {
  throw new Error('جلب ناقص: ' + rows.length + ' من ' + expected);
}

const byBranch = {};
for (const r of rows) {
  const br = BR[r && r.sto_name];
  if (br && BRANCHES_ON.indexOf(br) >= 0
      && r.itm_code !== undefined && r.itm_code !== null) {
    (byBranch[br] = byBranch[br] || []).push(r);
  }
}

const out = [];
for (const br of Object.keys(byBranch)) {
  const list = byBranch[br];
  for (let i = 0; i < list.length; i += ${CHUNK}) {
    out.push({ json: { p_branch: br, p_rows: list.slice(i, i + ${CHUNK}) } });
  }
}
if (out.length === 0) throw new Error('مفيش ولا صنف للفروع المفتوحة — راجع الجلب');
return out;
`.trim();

/* ── العقد ────────────────────────────────────────────────────────── */
const httpCommon = { retryOnFail: true, maxTries: 3, waitBetweenTries: 5000 };

const eplusNode = (name, jsonBody, pos, extraOptions) => ({
  parameters: {
    method: 'PATCH', url: EPLUS,
    authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth',
    sendBody: true,
    /* ⚠️ لازم specifyBody=json. «Using Fields Below» بتبعت الأرقام
       كنصوص والـAPI بتنهار بـaborted. */
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
  eplusNode('عدّ', '={{ JSON.stringify({ page_no: 1, page_size: 1 }) }}', [-1180, 300]),
  {
    parameters: { jsCode: codePages },
    type: 'n8n-nodes-base.code', typeVersion: 2,
    position: [-960, 300], name: 'صفحات',
  },
  /* ⚠️ التقطيع مقصود. n8n بيطلق نداء لكل عنصر **ورا بعض من غير أي
     مهلة** — يعني 70 نداء متتابعة على سيرفر الصيدلية وهو نفسه الجهاز
     اللي الكاشير شغّال عليه. 5 نداءات ثم ثانية راحة = ~14 ثانية زيادة
     على الجولة، مقابل إننا مانضغطش على السيرفر وقت الشغل. ولو حصل خلل،
     5 نداءات في الهوا أسهل في الإيقاف من 70. */
  eplusNode('جلب', '={{ JSON.stringify({ page_no: $json.no, page_size: $json.size }) }}', [-740, 300],
            { batching: { batch: { batchSize: 5, batchInterval: 1000 } } }),
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

/* سلسلة واحدة — مفيش تفريع ومفيش Merge.
   التفريع بيخلّي ترتيب التنفيذ معتمد على مكان العقدة على الشاشة، وعقدة
   Merge اللي بتستنى فرعين هي اللي جمّدت المزامنة يوم كامل بالساكت. */
const connections = {
  'كل ساعة': { main: [[{ node: 'عدّ',    type: 'main', index: 0 }]] },
  'عدّ':     { main: [[{ node: 'صفحات',  type: 'main', index: 0 }]] },
  'صفحات':   { main: [[{ node: 'جلب',    type: 'main', index: 0 }]] },
  'جلب':     { main: [[{ node: 'تقسيم',  type: 'main', index: 0 }]] },
  'تقسيم':   { main: [[{ node: 'كتابة',  type: 'main', index: 0 }]] },
};

const wf = { name: 'المخزون — لقطة كاملة (الأربع فروع)', nodes, connections, pinData: {} };

const out = path.join(__dirname, '..', 'docs', 'n8n_stock_sync.json');
fs.writeFileSync(out, JSON.stringify(wf, null, 2), 'utf8');

/* فحص الناتج: JSON صالح · كود كل عقدة بيتحلّل · كل وصلة لعقدة موجودة ·
   مفيش أسرار · وكل نداء eplus بيستخدم Using JSON */
const back = JSON.parse(fs.readFileSync(out, 'utf8'));
let bad = 0;
for (const n of back.nodes) {
  if (n.type === 'n8n-nodes-base.code') {
    try { new Function(n.parameters.jsCode); }
    catch (e) { console.log('✗ كود «' + n.name + '» مكسور: ' + e.message); bad++; }
  }
  if (n.parameters && n.parameters.url === EPLUS && n.parameters.specifyBody !== 'json') {
    console.log('✗ «' + n.name + '» مش على Using JSON'); bad++;
  }
}
const names = new Set(back.nodes.map(n => n.name));
for (const [from, c] of Object.entries(back.connections)) {
  if (!names.has(from)) { console.log('✗ وصلة من عقدة مش موجودة: ' + from); bad++; }
  for (const t of c.main[0]) {
    if (!names.has(t.node)) { console.log('✗ وصلة لعقدة مش موجودة: ' + t.node); bad++; }
  }
}
if (/eyJ|service_role|password/i.test(JSON.stringify(back))) { console.log('✗ فيه سر'); bad++; }
console.log(bad ? '✗ فشل ' + bad
  : '✅ ' + back.nodes.length + ' عقد · JSON صالح · الكود بيتحلّل · Using JSON · مفيش أسرار');
console.log('الملف: ' + out);
