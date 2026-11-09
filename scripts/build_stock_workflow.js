/* يبني وركفلو n8n للمزامنة الفرقية للمخزون — **وركفلو واحد للأربع فروع**.
   التشغيل:  node scripts/build_stock_workflow.js
   الناتج :  docs/n8n_stock_incremental.json

   ليه سكربت مش ملف JSON مكتوب بالإيد: الكود اللي جوّه عقد n8n بيتخزّن
   كنص داخل JSON، فكتابته بالإيد معناها هروب أسطر وعلامات تنصيص يدوي —
   وأول غلطة بتبوّظ الملف كله من غير ما تبان. هنا الكود مكتوب طبيعي
   وJSON.stringify بيتولّى الهروب، والسكربت بيفحص الناتج في الآخر. */

const fs = require('fs');
const path = require('path');

const SB_URL   = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const EPLUS    = 'http://eplus.ebrahimhamdy.com/api/Item/SearchItem';
const CRED     = { id: 'uJYS75ZTBXnlYIqg', name: 'eplus' };  // الاعتماد الموجود في n8n
const WINDOW   = "={{ $now.plus({hour:-24}).format('yyyy-MM-dd HH:mm:ss') }}";
const CHUNK    = 2000;

/* ── كود عقدة التقسيم ─────────────────────────────────────────────── */
const codeSplit = `
// الفروع المفتوحة للكتابة. بنبدأ بالمعمورة لوحدها، وبعد التحقق
// نوسّع السطر ده — **من غير أي وركفلو جديد**:
//   const BRANCHES_ON = ['mamora','san','bishr','seyouf'];
const BRANCHES_ON = ['mamora'];

// ⚠️ eplus بيرجّع HTTP 200 حتى وهو فاشل، بغلاف
//    {"Message":"Fail","Error":"...","Data":[]}. يعني n8n بيعتبره
//    ناجح. من غير الفحص ده الفشل بيبان «يوم من غير حركة» — نجاح
//    كاذب بالظبط زي اللي بنحاربه.
function rowsOf(name) {
  const o = $(name).first().json;
  if (o.Error || o.Message === 'Fail') {
    throw new Error('eplus رفض «' + name + '»: ' + (o.Error || o.Message));
  }
  return o.Data || [];
}

// نداء واحد بيرجّع الأربع فروع. خريطة المخزن ← الفرع، نفس أسماء
// branches.aliases في القاعدة.
const BR = {
  'الصيدلية':        'mamora',
  'ابراهيم حمدي 2':  'san',
  'ابراهيم حمدي 3':  'bishr',
  'السيوف':          'seyouf',
};

// المفتاح فرع+كود مش كود لوحده: نفس الصنف بييجي مرة لكل مخزن
const map = new Map();
for (const r of [...rowsOf('lasttrans'), ...rowsOf('update')]) {
  const br = BR[r && r.sto_name];
  if (br && r.itm_code !== undefined && r.itm_code !== null) {
    map.set(br + '|' + r.itm_code, { br, r });
  }
}

const byBranch = {};
for (const { br, r } of map.values()) {
  if (BRANCHES_ON.includes(br)) (byBranch[br] = byBranch[br] || []).push(r);
}

const out = [];
for (const br of Object.keys(byBranch)) {
  const rows = byBranch[br];
  for (let i = 0; i < rows.length; i += ${CHUNK}) {
    out.push({ json: { p_branch: br, p_rows: rows.slice(i, i + ${CHUNK}) } });
  }
}

// حارس: جولة بترجّع صفر غالبًا نداء فشل واتبلع، مش يوم بلا حركة
if (out.length === 0) {
  throw new Error('مفيش ولا صنف للفروع المفتوحة — راجع النداءين');
}
return out;
`.trim();

/* ── العقد ────────────────────────────────────────────────────────── */
const eplusNode = (name, filterKey, pos) => ({
  parameters: {
    method: 'PATCH', url: EPLUS,
    authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth',
    sendBody: true,
    /* ⚠️ من غير page_no/page_size بقصد. الـAPI بيعمل GetRange بالحجم
       المطلوب من غير ما يقصّه على عدد النتائج، فـpage_size=5000 على
       1,300 نتيجة بيرجّع «Offset and length were out of bounds». */
    bodyParameters: { parameters: [{ name: filterKey, value: WINDOW }] },
    options: {},
  },
  type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
  position: pos, name,
  credentials: { httpBasicAuth: CRED },
});

const nodes = [
  {
    parameters: { rule: { interval: [{ field: 'hours', triggerAtMinute: 25 }] } },
    type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.3,
    position: [-1392, 1024], name: 'Schedule Trigger1',
  },
  eplusNode('lasttrans', 'itm_lasttrans_date_search', [-1120, 1024]),
  eplusNode('update',    'itm_update_date_search',    [-900, 1024]),
  {
    parameters: { jsCode: codeSplit },
    type: 'n8n-nodes-base.code', typeVersion: 2,
    position: [-680, 1024], name: 'تقسيم',
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
    position: [-460, 1024], name: 'كتابة',
    retryOnFail: true, maxTries: 3, waitBetweenTries: 5000,
  },
];

/* سلسلة واحدة بالترتيب — مش تفريع.
   التفريع بيخلّي ترتيب التنفيذ معتمد على مكان العقدة على الشاشة،
   فعقدة «تقسيم» ممكن تشتغل قبل ما «lasttrans» تخلّص. والسلسلة
   بتخلّي الترتيب مضمون، والتكلفة ثانيتين.
   (ونفس السبب اللي خلّانا نشيل عقدة Merge: الاعتماد على تزامن
    فرعين هو اللي جمّد المزامنة يوم كامل بالساكت.) */
const connections = {
  'Schedule Trigger1': { main: [[{ node: 'lasttrans', type: 'main', index: 0 }]] },
  'lasttrans':         { main: [[{ node: 'update',    type: 'main', index: 0 }]] },
  'update':            { main: [[{ node: 'تقسيم',     type: 'main', index: 0 }]] },
  'تقسيم':             { main: [[{ node: 'كتابة',     type: 'main', index: 0 }]] },
};

const wf = { name: 'المخزون — فرقي (الأربع فروع)', nodes, connections, pinData: {} };

const out = path.join(__dirname, '..', 'docs', 'n8n_stock_incremental.json');
fs.writeFileSync(out, JSON.stringify(wf, null, 2), 'utf8');

/* فحص: JSON صالح، كود العقد بيتحلّل، وكل وصلة بتشاور على عقدة موجودة */
const back = JSON.parse(fs.readFileSync(out, 'utf8'));
let bad = 0;
for (const n of back.nodes) {
  if (n.type === 'n8n-nodes-base.code') {
    try { new Function(n.parameters.jsCode); }
    catch (e) { console.log('✗ كود «' + n.name + '» مكسور: ' + e.message); bad++; }
  }
}
const names = new Set(back.nodes.map(n => n.name));
for (const [from, c] of Object.entries(back.connections)) {
  if (!names.has(from)) { console.log('✗ وصلة من عقدة مش موجودة: ' + from); bad++; }
  for (const t of c.main[0]) {
    if (!names.has(t.node)) { console.log('✗ وصلة لعقدة مش موجودة: ' + t.node); bad++; }
  }
}
if (/eyJ|service_role|password/i.test(JSON.stringify(back))) { console.log('✗ فيه سر في الملف'); bad++; }
console.log(bad ? '✗ فشل ' + bad : '✅ ' + back.nodes.length + ' عقد · JSON صالح · الكود بيتحلّل · مفيش أسرار');
console.log('الملف: ' + out);
