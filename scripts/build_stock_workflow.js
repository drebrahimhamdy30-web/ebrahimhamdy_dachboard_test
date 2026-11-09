/* يبني ملف وركفلو n8n للمزامنة الفرقية للمخزون.
   التشغيل:  node scripts/build_stock_workflow.js
   الناتج :  docs/n8n_stock_incremental_mamora.json  (يتلصق في n8n)

   ليه سكربت مش ملف JSON مكتوب بالإيد: الكود اللي جوّه عقد n8n بيتخزّن
   كنص داخل JSON، فكتابته بالإيد معناها هروب أسطر وعلامات تنصيص يدوي —
   وأول غلطة بتبوّظ الملف كله من غير ما تبان. هنا الكود مكتوب طبيعي
   وJSON.stringify بيتولّى الهروب. */

const fs = require('fs');
const path = require('path');

const SB_URL  = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const EPLUS   = 'https://eplus.ebrahimhamdy.com/api/Item/SearchItem';
const BRANCH  = 'mamora';
const HOURS   = 24;     // اتساع النافذة
const CHUNK   = 2000;   // أقصى عدد صفوف في نداء كتابة واحد

/* ── كود عقدة النافذة ─────────────────────────────────────────────── */
const codeWindow = `
// النافذة: آخر ${HOURS} ساعة من الحركة. مفيش حالة محفوظة — كل جولة
// بتجيب نفس الاتساع، فلو جولة (أو عشرة) فشلت، أول جولة ناجحة بتلحق
// اللي فات لوحدها.
//
// ⚠️ القاهرة صراحةً. السيرفر UTC، والفرق ساعتين (تلاتة صيفًا) كفيل
//    إنه يضيّع حركة لو حسبناها بتوقيت السيرفر.
const since = DateTime.now()
  .setZone('Africa/Cairo')
  .minus({ hours: ${HOURS} })
  .toFormat("yyyy-MM-dd'T'HH:mm:ss");

return [{ json: { since, branch: '${BRANCH}' } }];
`.trim();

/* ── كود عقدة الدمج ───────────────────────────────────────────────── */
const codeMerge = `
// بيجمع ناتج النداءين، يشيل التكرار، ويقسّم على دفعات للكتابة.
const CHUNK = ${CHUNK};

// الـAPI ممكن يرجّع مصفوفة مباشرة أو كائن جوّاه المصفوفة — نتعامل مع
// الاتنين بدل ما نفترض شكل واحد.
function rowsOf(nodeName) {
  const items = $(nodeName).all().map(i => i.json);
  if (items.length === 1 && items[0] && items[0].itm_code === undefined) {
    const o = items[0];
    return o.data || o.items || o.result || o.Data || [];
  }
  return items;
}

const qty    = rowsOf('الكميات');
const prices = rowsOf('الأسعار');

// نفس الصنف ممكن يكون في النداءين — الأحدث يغلب
const map = new Map();
for (const r of [...qty, ...prices]) {
  if (r && r.itm_code !== undefined && r.itm_code !== null) {
    map.set(String(r.itm_code), r);
  }
}
const rows = [...map.values()];

// حارس: جولة بترجّع صفر غالبًا نداء فشل واتبلع، مش يوم بلا حركة.
// بنوقف بصوت بدل ما نكتب لا حاجة ونقول تمام.
if (rows.length === 0) {
  throw new Error('مفيش ولا صنف من النداءين — راجع الجلب قبل ما تثق في الجولة');
}

// حارس تاني: نافذة ${HOURS} ساعة المفروض ترجّع آلاف مش عشرات الآلاف.
// رقم ضخم معناه الفلتر اتجاهل والـAPI رجّع الكتالوج كله.
if (rows.length > 15000) {
  throw new Error('الفلتر غالبًا اتجاهل — رجع ' + rows.length + ' صنف');
}

const out = [];
for (let i = 0; i < rows.length; i += CHUNK) {
  out.push({ json: { p_branch: '${BRANCH}', p_rows: rows.slice(i, i + CHUNK) } });
}
return out;
`.trim();

/* ── العقد ────────────────────────────────────────────────────────── */
const httpCommon = {
  retryOnFail: true,
  maxTries: 3,
  waitBetweenTries: 5000,
};

const nodes = [
  {
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 10 }] } },
    id: 'sched-1', name: 'كل 10 دقايق',
    type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.2,
    position: [-220, 300],
  },
  {
    parameters: { jsCode: codeWindow },
    id: 'win-1', name: 'النافذة',
    type: 'n8n-nodes-base.code', typeVersion: 2,
    position: [0, 300],
  },
  {
    parameters: {
      method: 'PATCH', url: EPLUS,
      authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth',
      sendBody: true, specifyBody: 'json',
      jsonBody: '={{ JSON.stringify({ itm_lasttrans_date_search: $json.since, page_no: 1, page_size: 5000 }) }}',
      options: { timeout: 120000 },
    },
    id: 'qty-1', name: 'الكميات',
    type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [220, 300],
    credentials: { httpBasicAuth: { name: 'eplus' } },
    ...httpCommon,
  },
  {
    parameters: {
      method: 'PATCH', url: EPLUS,
      authentication: 'genericCredentialType', genericAuthType: 'httpBasicAuth',
      sendBody: true, specifyBody: 'json',
      jsonBody: "={{ JSON.stringify({ itm_update_date_search: $('النافذة').first().json.since, page_no: 1, page_size: 5000 }) }}",
      options: { timeout: 120000 },
    },
    id: 'prc-1', name: 'الأسعار',
    type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [440, 300],
    credentials: { httpBasicAuth: { name: 'eplus' } },
    ...httpCommon,
  },
  {
    parameters: { jsCode: codeMerge },
    id: 'mrg-1', name: 'دمج',
    type: 'n8n-nodes-base.code', typeVersion: 2,
    position: [660, 300],
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
    id: 'wr-1', name: 'كتابة المخزون',
    type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2,
    position: [880, 300],
    ...httpCommon,
  },
];

/* سلسلة واحدة بالترتيب — مفيش تفريع ومفيش Merge.
   النداءين وراء بعض بقصد: عقدة Merge اللي بتستنى فرعين هي بالظبط
   اللي جمّدت مزامنة فرع يوم كامل بالساكت. */
const connections = {
  'كل 10 دقايق': { main: [[{ node: 'النافذة',       type: 'main', index: 0 }]] },
  'النافذة':      { main: [[{ node: 'الكميات',       type: 'main', index: 0 }]] },
  'الكميات':      { main: [[{ node: 'الأسعار',       type: 'main', index: 0 }]] },
  'الأسعار':      { main: [[{ node: 'دمج',           type: 'main', index: 0 }]] },
  'دمج':          { main: [[{ node: 'كتابة المخزون', type: 'main', index: 0 }]] },
};

const wf = {
  name: 'مخزون المعمورة — فرقي',
  nodes,
  connections,
  settings: { executionOrder: 'v1' },
};

const out = path.join(__dirname, '..', 'docs', 'n8n_stock_incremental_mamora.json');
fs.writeFileSync(out, JSON.stringify(wf, null, 2), 'utf8');

/* فحص: الملف لازم يتقرا JSON صالح، وكود العقد لازم يتحلّل JavaScript */
const back = JSON.parse(fs.readFileSync(out, 'utf8'));
let bad = 0;
for (const n of back.nodes) {
  if (n.type === 'n8n-nodes-base.code') {
    try { new Function(n.parameters.jsCode); }
    catch (e) { console.log('✗ كود العقدة «' + n.name + '» مكسور: ' + e.message); bad++; }
  }
}
const names = new Set(back.nodes.map(n => n.name));
for (const [from, c] of Object.entries(back.connections)) {
  if (!names.has(from)) { console.log('✗ وصلة من عقدة مش موجودة: ' + from); bad++; }
  for (const t of c.main[0]) {
    if (!names.has(t.node)) { console.log('✗ وصلة لعقدة مش موجودة: ' + t.node); bad++; }
  }
}
console.log(bad ? '✗ فشل ' + bad : '✅ ' + back.nodes.length + ' عقد — JSON صالح والكود بيتحلّل');
console.log('الملف: ' + out);
