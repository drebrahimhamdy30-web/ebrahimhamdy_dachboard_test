/* ═══════════════════════════════════════════════════════════════════
   فروع Phalix — المصدر الوحيد لأسماء الفروع وأكوادها وأسمائها البديلة
   ═══════════════════════════════════════════════════════════════════
   قبل الملف ده كانت الفروع مكتوبة كمصفوفات ثابتة في ~20 صفحة:
       ['المعمورة','سان ستيفانو','سيدى بشر']
       { mamora:'المعمورة', san:'سان ستيفانو', bishr:'سيدى بشر' }
       { 'المعمورة':'الصيدلية', 'سان ستيفانو':'ابراهيم حمدي 2', ... }
   وقايمة UUIDs مكتوبة صريح في شاشة التوزيع. يعني فتح فرع رابع = تعديل
   20 ملف، والنسيان في واحد بيسيب شاشة شايفة فرعين بس من غير أي رسالة.

   دلوقتي المصدر جدول branches (id, name, code, aliases, sort_order,
   is_active) — والوحدة دي بتقرأه مرة واحدة وتكاشه.

   ⚠️ لازم يتحمّل بعد config.js:
       <script src="config.js?v=..."></script>
       <script src="branches.js?v=..."></script>

   ⚠️ البيانات بتتحمّل **غير متزامنة**. الصفحات بتشتغل على الكاش فورًا
      (من آخر مرة) وبتتحدّث لما الجلب يخلص. لو الصفحة محتاجة تتأكد إنها
      على أحدث نسخة تستنّى Branches.ready().
   ═══════════════════════════════════════════════════════════════════ */

const Branches = (function () {

  const CACHE_KEY = 'phalix_branches_v1';

  /* آخر ملاذ لو مفيش كاش ولا شبكة — نفس الفروع الحالية. مش المصدر:
     أول جلب ناجح بيستبدلها.                                        */
  const FALLBACK = [
    { id: null, name: 'المعمورة',    code: 'mamora', aliases: ['الصيدلية'],        sort_order: 1 },
    { id: null, name: 'سان ستيفانو', code: 'san',    aliases: ['ابراهيم حمدي 2'],  sort_order: 2 },
    { id: null, name: 'سيدى بشر',    code: 'bishr',  aliases: ['ابراهيم حمدي 3'],  sort_order: 3 }
  ];

  let _list = null;
  let _ready = null;
  const _subs = [];

  function _norm(rows) {
    return (rows || [])
      .filter(b => b && b.name)
      .map(b => ({
        id:         b.id || null,
        name:       String(b.name).trim(),
        code:       b.code || null,
        aliases:    Array.isArray(b.aliases) ? b.aliases.filter(Boolean) : [],
        sort_order: b.sort_order == null ? 999 : b.sort_order
      }))
      .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name, 'ar'));
  }

  // كاش فوري عشان الصفحة ترسم من غير ما تستنّى الشبكة
  try {
    const c = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
    if (c && c.length) _list = _norm(c);
  } catch (e) {}
  if (!_list) _list = _norm(FALLBACK);

  function _apply(rows) {
    const n = _norm(rows);
    if (!n.length) return false;
    _list = n;
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(n)); } catch (e) {}
    _publishGlobals();
    _subs.forEach(fn => { try { fn(_list); } catch (e) {} });
    return true;
  }

  /* التوافق مع الكود القائم: صفحات بتقرأ window.ORG_BRANCHES و
     orgBranchAlias() اللي كان بيملأهم محمّل الهوية.               */
  function _publishGlobals() {
    window.ORG_BRANCHES = _list.map(b => b.name);
    const m = {};
    _list.forEach(b => { m[b.name] = b.name; b.aliases.forEach(a => { m[a] = b.name; }); });
    window.ORG_BRANCH_ALIAS = m;
  }
  _publishGlobals();

  function load(force) {
    if (_ready && !force) return _ready;
    _ready = (async function () {
      try {
        const r = await fetch(
          `${PHALIX_CONFIG.supabaseUrl}/rest/v1/branches` +
          `?select=id,name,code,aliases,sort_order,is_active&is_active=eq.true&order=sort_order`,
          // توكن المستخدم لو موجود — الجدول بقى authenticated-only.
          // (الجلب الاستباقي على صفحة الدخول بيفشل بهدوء والكاش بيغطّي.)
          { headers: await Session.headers() });
        if (r.ok) _apply(await r.json());
      } catch (e) {}
      return _list;
    })();
    return _ready;
  }

  const ready = () => load();
  function onChange(fn) { if (typeof fn === 'function') { _subs.push(fn); fn(_list); } }

  /* ── القراءة ─────────────────────────────────────────────────── */
  const all    = () => _list.slice();
  const names  = () => _list.map(b => b.name);
  const codes  = () => _list.map(b => b.code).filter(Boolean);
  const ids    = () => _list.map(b => b.id).filter(Boolean);

  const byName = n => _list.find(b => b.name === String(n || '').trim()) || null;
  const byCode = c => _list.find(b => b.code === String(c || '').trim()) || null;
  const byId   = i => _list.find(b => b.id === String(i || '').trim()) || null;

  /* toName: بياخد أي شكل (اسم، كود، اسم بديل، uuid) ويرجّع الاسم القياسي.
     ده بديل خرايط الـalias اللي كانت متكررة في كل صفحة.            */
  function toName(v) {
    const s = String(v == null ? '' : v).trim();
    if (!s) return '';
    for (const b of _list) {
      if (b.name === s || b.code === s || b.id === s) return b.name;
      if (b.aliases.indexOf(s) >= 0) return b.name;
    }
    return s;   // مش فرع معروف — نسيبه زي ما هو بدل ما نضيّعه
  }
  function toCode(v) { const b = byName(toName(v)); return b ? b.code : null; }
  function toId(v)   { const b = byName(toName(v)); return b ? b.id   : null; }

  /* مقارنة فرعين مهما كان شكل كل واحد (اسم/كود/اسم بديل/تهجئة بديلة).
     ⚠️ المقارنة الحرفية (a === b) هي اللي عملت باج inventory_min: البيانات
     فيها «سيدى بشر» والفلتر بيبعت «سيدي بشر» فالنتيجة صفر صف من غير أي
     رسالة خطأ. same() بتطبّع الطرفين الأول.                             */
  function same(a, b) {
    const x = toName(a), y = toName(b);
    return !!x && !!y && x === y;
  }

  /* خرايط جاهزة — الصفحات كانت بتكتبها بنفسها.
     ⚠️ بترجّع نسخة جديدة كل نداء: لو الفروع اتحدّثت من الشبكة بعد ما
     الصفحة خزّنت الخريطة في const، الخريطة القديمة تفضل قديمة. للصفحات
     اللي بتفضل مفتوحة طويل استعمل Branches.onChange().               */
  function codeMap()  { const m = {}; _list.forEach(b => { if (b.code) m[b.code] = b.name; }); return m; }
  function storeMap() { const m = {}; _list.forEach(b => { m[b.name] = b.aliases[0] || b.name; }); return m; }
  function aliasMap() { const m = {}; _list.forEach(b => { m[b.name] = b.name; b.aliases.forEach(a => { m[a] = b.name; }); }); return m; }

  /* الاسم في نظام eplus/المخزن — أول اسم بديل */
  function storeName(v) {
    const b = byName(toName(v));
    return (b && b.aliases[0]) || toName(v);
  }
  /* العكس: اسم المخزن → اسم الفرع (toName بتعمله أصلًا، بس الاسم ده أوضح) */
  const fromStoreName = toName;

  /* ── ملء قائمة اختيار ────────────────────────────────────────────
     fillSelect(el)                        → الفروع بس
     fillSelect(el, {all:'كل الفروع'})     → مع خيار «الكل» بقيمة ''
     fillSelect(el, {value:'code'})        → القيمة كود بدل الاسم
     بتحافظ على الاختيار الحالي لو لسه موجود.                       */
  function fillSelect(el, opts) {
    const e = typeof el === 'string' ? document.getElementById(el) : el;
    if (!e) return;
    const o = opts || {};
    const keep = e.value;
    const val = b => (o.value === 'code' ? (b.code || b.name)
                   : o.value === 'id'   ? (b.id   || b.name)
                   : b.name);
    let html = '';
    if (o.all) html += '<option value="' + (o.allValue == null ? '' : o.allValue) + '">' + o.all + '</option>';
    html += _list.map(b => '<option value="' + val(b).replace(/"/g, '&quot;') + '">' + b.name + '</option>').join('');
    e.innerHTML = html;
    if (keep && Array.prototype.some.call(e.options, x => x.value === keep)) e.value = keep;
  }

  /* ── ملء تلقائي تصريحي ───────────────────────────────────────────
     أي <select data-branches> بيتملى لوحده — والخيارات اللي مش فروع
     («كل الفروع»، «اختر الفرع…»، «عام») تفضل مكتوبة في الـHTML زي ما هي.

         <select data-branches>           القيمة = اسم الفرع
         <select data-branches="code">    القيمة = الكود المختصر
         <select data-branches="store">   القيمة = اسم المخزن في eplus
         <select data-branches="id">      القيمة = uuid

     ⚠️ الخيارات اللي بنضيفها بتتعلّم بـdata-b عشان نقدر نستبدلها لما
     الفروع توصل من الشبكة من غير ما نمسح خيارات الصفحة.              */
  function _fill(sel) {
    const kind = sel.getAttribute('data-branches') || 'name';
    const keep = sel.value;
    Array.prototype.slice.call(sel.querySelectorAll('option[data-b]')).forEach(o => o.remove());
    const val = b => kind === 'code'  ? (b.code || b.name)
                   : kind === 'id'    ? (b.id   || b.name)
                   : kind === 'store' ? (b.aliases[0] || b.name)
                   : b.name;
    _list.forEach(b => {
      const o = document.createElement('option');
      o.value = val(b);
      o.textContent = b.name;
      o.setAttribute('data-b', '1');
      sel.appendChild(o);
    });
    // خيار عليه data-after بيرجع آخر القائمة (زي «عام» بعد الفروع)
    Array.prototype.slice.call(sel.querySelectorAll('option[data-after]'))
      .forEach(o => sel.appendChild(o));
    if (keep && Array.prototype.some.call(sel.options, x => x.value === keep)) sel.value = keep;
  }

  function autofill(root) {
    const scope = root || document;
    if (!scope.querySelectorAll) return;
    Array.prototype.slice.call(scope.querySelectorAll('select[data-branches]')).forEach(_fill);
  }

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', function () { autofill(); });
  else autofill();

  _subs.push(function () { autofill(); });   // إعادة ملء لما الفروع توصل

  load();   // جلب استباقي — الصفحة شغّالة على الكاش لحد ما يخلص

  return { all, names, codes, ids, byName, byCode, byId,
           codeMap, storeMap, aliasMap,
           toName, toCode, toId, same, storeName, fromStoreName,
           fillSelect, autofill, load, ready, onChange };
})();

/* التوافق: الدالة دي كانت متعرّفة في محمّل الهوية */
window.orgBranchAlias = function (raw) { return Branches.toName(raw); };
