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
   · **تكلفة البحث من الحروف مش الطول** (مقيس على 27,821 كود):
     الرقم الواحد 0–9 بيرجّع ~10,800 صنف، لكن 'sr' بيرجّع 9 و'z'
     بيرجّع 1. فالمستبعد = **العشرة أرقام بس** (3 منهم ليهم رصيد)،
     واللقطة الليلية بتغطّيهم. قاعدة «أقل من 4 حروف» القديمة كانت
     بترمي 906 كود منهم 339 ليهم رصيد — ومنهم 'sr' سرنجات 3 سم
     كبار برصيد 3,926.
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

/* إيقاع الجولة. التغطية الراجعة لازم تفضل **أكبر من زمن الجولة نفسها**:
   الختم بيتسجّل وقت الكتابة، والسؤال حصل قبله بثواني/دقايق، فاللي
   اتغيّر في النص ما كانش في قايمة الأكواد. وفي نفس الوقت تغطية أوسع
   من اللازم = إعادة جلب نفس الأكواد كل جولة (مش ضار — الكتابة
   idempotent — بس نداءات على الفاضي). فبنربطها بالإيقاع. */
const EVERY    = 5;     // دقايق بين الجولات
const OVERLAP  = EVERY; // تغطية راجعة = الإيقاع (≈7 أضعاف زمن الجولة)
const MAXHOURS = 6;     // سقف النافذة؛ فوقه capped واللقطة الليلية هي الحل
/* الكود اللي بحثه بيرجّع نص الكتالوج. التكلفة بتتحدد **بالحروف مش
   بالطول** (مقيس على 27,821 كود): الرقم الواحد 0–9 بيرجّع ~10,800
   صنف، لكن 'sr' بيرجّع 9 و'z' بيرجّع 1 و'b' بيرجّع 34. فالأكواد
   القصيرة اللي فيها حرف **أرخص** من الطويلة أحيانًا — ومنها أصناف
   مهمة زي 'sr' (سرنجات 3 سم كبار، رصيد 3,926).
   الاستبعاد اتضيّق من «أقل من 4 حروف» (906 كود، 339 منهم له رصيد)
   لـ«رقم واحد بس» (10 أكواد، 3 منهم له رصيد). أتقل نداء باقي بقى
   1,644 صنف — عادي خالص. */
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
                  // أسماء الأكواد اللي بتتجاب بالاسم بدل الكود
                  heavy: w.heavy || {},
                  oldest: w.oldest || null, notes: notes } }];
`.trim();

/* ── كود عقدة «أكواد» ─────────────────────────────────────────────── */
const codeCodes = `
const MAXCODES = ${MAXCODES};

/* ── اختيار طريقة البحث: الأطول يكسب ──────────────────────────────
   البحث في eplus **جزئي** في الحالتين، فتكلفته = كام صنف في
   الكتالوج فيه النص ده. يعني النص القصير غالي والطويل رخيص، سواء
   كان كود أو اسم. القياس على 27,821 صنف (2026-11-10):

     كود '6'   → 15,668 صنف   |   اسمه 'ريد اقراص 60 قرص'  →  1
     كود '7068'→     12 صنف   |   اسمه 'ي'                 → 24,123

   والعيبين **متكاملين**: كل صنف اسمه غالي كوده رخيص والعكس. فمفيش
   داعي لقايمة استثناءات ولا سؤال للقاعدة — نبص على الطول ونختار.
   على الـ588 صنف الأصعب (كل اللي اسمه قصير أو كوده قصير): متوسط
   النتايج 2، وأسوأ نداء 166، وولا واحد فوق 300.
   التعادل بيروح للكود (قيس: '250مل' بالاسم 366 وبالكود 1).

   والاسم جاي من رد التغيّرات نفسه — يعني اسم eplus الحالي، مش نسخة
   عندنا ممكن تكون قديمة. ولو الرد ماجابش اسم، بنرجع لخريطة
   stock_sync_window، وآخر حل الكود. */
const HEAVY  = $('تحقق').first().json.heavy || {};
const pickName = (code, name) =>
  (name && name.trim().length > code.length) ? name.trim() : null;

// مخازن فروعنا — الرد بيرجّع مخازن تانية (طوسون، سندره، العجز) مش بتاعتنا
const STORES = ['الصيدلية', 'ابراهيم حمدي 2', 'ابراهيم حمدي 3', 'السيوف'];

/* مصدرين للتغيير، لأن eplus بتمسك كل واحد في حقل لوحده:
     last_trans_date → حركة الكمية (بيع/شراء/مرتجع)
     update_date     → تعديل الصنف نفسه (سعر، اسم، شركة، تصنيف)
   الاتنين مستقلين: صنف 7228 بيع النهاردة (last_trans 11/10) وآخر
   تعديل بياناته 7/28. فالسعر اللي بيتغيّر من غير بيع **مش** بيظهر في
   نداء الكمية خالص — و~25 صنف في اليوم بيتغيّر سعرهم في المعمورة.
   والصنف الجديد متغطّي هنا كمان: update_date بيتحط وقت الإنشاء
   (مُتحقَّق على 23,225 صف: ولا واحد update أقدم من insert). */
const rows = [];
for (const src of ['تغيّرات الكمية', 'تغيّرات الصنف']) {
  const o = $(src).first().json;
  if (o.Error || String(o.Message).toLowerCase() === 'fail') {
    throw new Error('eplus رفض «' + src + '»: ' + (o.Error || o.Message));
  }
  for (const r of (o.Data || [])) rows.push(r);
}

// ⚠️ الكميات في الرد ده **ناقصة** (بتاعة الدفعات اللي اتحركت بس).
//    إحنا عايزين الأكواد لا غير.
const codes = new Map();   // كود → اسم نبحث بيه (أو null = نبحث بالكود)
let stuck = [], other = 0;
for (const r of rows) {
  if (!r || r.itm_code === undefined || r.itm_code === null) continue;
  if (STORES.indexOf(r.sto_name) < 0) { other++; continue; }
  const c = String(r.itm_code).trim();
  if (!c) continue;
  if (codes.has(c)) continue;

  const name = pickName(c, r.itm_name_ar) || pickName(c, HEAVY[c]);
  /* كود من خانة واحدة بلا اسم أطول منه = مفيش نص انتقائي نبحث بيه.
     البحث بالكود هيجيب نص الكتالوج، فبيتأجّل للّقطة الكاملة —
     وبيتكتب في السجل مش بيختفي في السكوت. */
  if (!name && c.length <= 1) { stuck.push(c); continue; }
  codes.set(c, name);
}

if (codes.size > MAXCODES) {
  throw new Error('عدد الأكواد ' + codes.size + ' فوق الحد ' + MAXCODES +
    ' — الجولة دي هتتعدّى على اللي بعدها، شغّل اللقطة الكاملة');
}
// مفيش تغيير أصلًا = جولة شرعية (ساعة هادية). مش خطأ.
const byName = [...codes].filter(e => e[1]).length;
console.log('نافذة ' + $('تحقق').first().json.gap_minutes + 'د · ' + rows.length +
  ' صف · ' + codes.size + ' كود (' + byName + ' بالاسم · ' +
  (codes.size - byName) + ' بالكود) · مخازن تانية ' + other +
  (stuck.length ? ' · اتأجّل للّقطة: ' + stuck.join(',') : ''));
return [...codes].map(([code, name]) =>
  ({ json: { code: code, name: name, total: codes.size } }));
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
const got = new Set();   // كود رجع فعلًا — حتى لو فرعه مقفول
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
    got.add(code);
    const br = BR[r.sto_name];
    if (!br || BRANCHES_ON.indexOf(br) < 0) continue;
    map.set(br + '|' + code, r);
  }
}

if (map.size === 0) {
  throw new Error('ولا صف مطابق من ' + seen + ' صف رجعوا — راجع الفلترة');
}

/* كود طلبناه و**ولا صف رجع ليه خالص**. السبب الوارد: اسمه اتغيّر في
   eplus بعد آخر مزامنة فالبحث بالاسم مالقاهوش. بيتكتب في السجل عشان
   ما يختفيش في السكوت.
   ⚠️ الكود اللي رجع بس فرعه مقفول **مش** ضايع — عشان كده "got"
   بتتملى جوّه اللفة قبل فلتر الفرع، مش من "map". */
const lost = [...asked].filter(c => !got.has(c));

const byBranch = {};
for (const [k, r] of map) {
  const br = k.split('|')[0];
  (byBranch[br] = byBranch[br] || []).push(r);
}

console.log('رجع ' + seen + ' صف · مطابق ' + map.size + ' · مرفوض ' + stray +
  ' · ' + Object.keys(byBranch).map(b => b + '=' + byBranch[b].length).join(' ') +
  (lost.length ? ' · مارجعش: ' + lost.slice(0, 20).join(',') : ''));

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
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: EVERY }] } },
    type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.3,
    position: [-1620, 300], name: 'كل شوية',
  },
  /* النافذة من آخر كتابة ناجحة في جداول الفروع المفتوحة — مش من الساعة.
     بترجّع التاريخ جاهز بتوقيت القاهرة naive زي ما eplus عايزه، فمفيش
     تحويل توقيت في n8n أصلًا (السيرفر UTC والفرق بيتغيّر مع DST). */
  sbNode('نافذة', 'stock_sync_window',
    '={{ JSON.stringify({ p_branches: ' + JSON.stringify(BRANCHES) +
      ', p_overlap_minutes: ' + OVERLAP + ', p_max_hours: ' + MAXHOURS + ' }) }}',
    [-1400, 300]),
  codeNode('تحقق', codeGuard, [-1180, 300]),
  /* نداءين للتغيير، لأن eplus بتمسك كل نوع في حقل مستقل. سلسلة مش
     تفريع — التفريع بيخلّي ترتيب التنفيذ معتمد على مكان العقدة. */
  eplusNode('تغيّرات الكمية',
    '={{ JSON.stringify({ itm_lasttrans_date_search: $json.since }) }}',
    [-1000, 300]),
  /* ⚠️ العقدة دي جاية بعد نداء تاني، فـ$json بقى رد eplus مش النافذة
     — لازم نرجع لـ«تحقق» بالاسم. */
  eplusNode('تغيّرات الصنف',
    "={{ JSON.stringify({ itm_update_date_search: $('تحقق').first().json.since }) }}",
    [-820, 300]),
  codeNode('أكواد', codeCodes, [-640, 300]),
  /* نداء خفيف لكل كود، واحد في المرة بثانية راحة. ده عكس صفحات اللقطة
     الكاملة اللي بتخلّي الـAPI تمسح الكتالوج كله في كل نداء. */
  /* الكود الرقمي الواحد بحثه بيجيب نص الكتالوج، فبيتجاب بالاسم —
     `itm_name_ar_search` بالاسم الكامل بيرجّع 1–7 نتايج. و«تقسيم»
     بيفلتر على الكود بالحرف في الحالتين فالنتيجة واحدة. */
  eplusNode('رصيد',
    '={{ JSON.stringify($json.name ? { itm_name_ar_search: $json.name }'
    + ' : { itm_code_search: $json.code }) }}',
    [-460, 300], { batching: { batch: { batchSize: 1, batchInterval: 1000 } } }),
  codeNode('تقسيم', codeSplit, [-280, 300]),
  sbNode('كتابة', 'upsert_branch_stock', '={{ JSON.stringify($json) }}', [-100, 300]),
];

const order = ['كل شوية', 'نافذة', 'تحقق', 'تغيّرات الكمية', 'تغيّرات الصنف',
               'أكواد', 'رصيد', 'تقسيم', 'كتابة'];
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

/* ══════════════════════════════════════════════════════════════════
   وركفلو تانٍ: تكميل الصفوف الشحيحة (مرة واحدة بزرار)
   ══════════════════════════════════════════════════════════════════
   تحميل تقرير الإكسل 2026-11-10 رمّم الأرصدة، بس التقرير مافيهوش
   أعمدة الباركود والاسم الإنجليزي وعلامة الدوا — فالأصناف اللي
   ماكانتش موجودة عندنا قبل كده اتكتبت بصف شحيح (190 صنف له رصيد،
   و~4,400 برصيد صفر).

   الصفوف دي بتتصلّح لوحدها أول ما الصنف يتباع (الفرقي بيجيبه كامل
   من eplus)، بس ده ممكن ياخد شهور للصنف البطيء. الوركفلو ده بيجيبهم
   دفعة واحدة بنفس النداء الخفيف.

   نفس سلسلة الوركفلو الأساسي من «رصيد» ورايح — بنفس الكود بالحرف.
   المختلف بس: مصدر الأكواد (القاعدة بدل eplus) والتشغيل (زرار بدل
   جدولة).  */

const codeBackfill = `
const o = $('ناقص').first().json;
const items = (o && o.items) || [];
if (!items.length) {
  throw new Error('مفيش صفوف شحيحة — مفيش شغل');
}
/* نفس قاعدة الوركفلو الأساسي: الأطول يكسب. الاسم العربي موجود في
   الصف الشحيح (جاي من التقرير)، فمعظمهم هيتجابوا بالاسم. */
const pickName = (code, name) =>
  (name && name.trim().length > code.length) ? name.trim() : null;

const out = [];
let stuck = [];
for (const it of items) {
  const c = String(it.code || '').trim();
  if (!c) continue;
  const name = pickName(c, it.name);
  if (!name && c.length <= 1) { stuck.push(c); continue; }
  out.push({ json: { code: c, name: name, total: items.length } });
}
console.log('شحيح ' + items.length + ' · هيتجاب ' + out.length +
  (stuck.length ? ' · متعذّر: ' + stuck.join(',') : ''));
return out;
`.trim();

const bfNodes = [
  { parameters: {}, type: 'n8n-nodes-base.manualTrigger', typeVersion: 1,
    position: [-1000, 300], name: 'تشغيل يدوي' },
  sbNode('ناقص', 'stock_incomplete_codes',
    '={{ JSON.stringify({ p_branch: ' + JSON.stringify(BRANCHES[0]) +
      ', p_limit: 500, p_with_stock: true }) }}',
    [-800, 300]),
  codeNode('أكواد', codeBackfill, [-600, 300]),
  eplusNode('رصيد',
    '={{ JSON.stringify($json.name ? { itm_name_ar_search: $json.name }'
    + ' : { itm_code_search: $json.code }) }}',
    [-400, 300], { batching: { batch: { batchSize: 1, batchInterval: 1000 } } }),
  codeNode('تقسيم', codeSplit, [-200, 300]),
  sbNode('كتابة', 'upsert_branch_stock', '={{ JSON.stringify($json) }}', [0, 300]),
];
const bfOrder = ['تشغيل يدوي', 'ناقص', 'أكواد', 'رصيد', 'تقسيم', 'كتابة'];
const bfConn = {};
for (let i = 0; i < bfOrder.length - 1; i++) {
  bfConn[bfOrder[i]] = { main: [[{ node: bfOrder[i + 1], type: 'main', index: 0 }]] };
}
const bfPath = path.join(__dirname, '..', 'docs', 'n8n_stock_backfill.json');
fs.writeFileSync(bfPath, JSON.stringify(
  { name: 'المخزون — تكميل الصفوف الشحيحة', nodes: bfNodes, connections: bfConn, pinData: {} },
  null, 2), 'utf8');

const bf = JSON.parse(fs.readFileSync(bfPath, 'utf8'));
let bfBad = 0;
const bfNames = new Set(bf.nodes.map(n => n.name));
for (const n of bf.nodes) {
  if (n.type === 'n8n-nodes-base.code') {
    try { new Function(n.parameters.jsCode); }
    catch (e) { console.log('x كود «' + n.name + '»: ' + e.message); bfBad++; }
    for (const m of n.parameters.jsCode.matchAll(/\$\('([^']+)'\)/g)) {
      if (!bfNames.has(m[1])) { console.log('x «' + n.name + '» بينادي عقدة مش موجودة: ' + m[1]); bfBad++; }
    }
  }
}
if (/eyJ|service_role|password/i.test(JSON.stringify(bf))) { console.log('x فيه سر'); bfBad++; }
console.log(bfBad ? 'x التكميل فشل ' + bfBad
  : 'OK ' + bf.nodes.length + ' عقد · تكميل الصفوف الشحيحة (' + BRANCHES[0] + ')');
console.log('الملف: ' + bfPath);
