/* ═══════════════════════════════════════════════════════════════════
   كتالوج شاشات Phalix — المصدر الوحيد لاسم الشاشة ومجموعتها ومفتاحها
   ═══════════════════════════════════════════════════════════════════
   قبل الملف ده كان الكتالوج مكتوب **مرتين** في الكود: مرة في
   delivery/app.html (للقائمة) ومرة في delivery/pages/permissions.html
   (لشاشة الصلاحيات) — وكانوا مختلفين في 42 موضع:

     • customer_problems: اسمها «تعليمات عامة» في القائمة و«مشاكل
       العملاء» في شاشة الصلاحيات — الأدمن بيدّي صلاحية لشاشة باسم
       والمستخدم بيشوفها باسم تاني.
     • المجموعات مختلفة تمامًا: القائمة فيها 9 مجموعات وشاشة الصلاحيات
       فيها 4.
     • 4 شاشات (المصروفات، الربط بالمصادر، أسعار الزيوت، أرصدة نقاط
       البيع) مكانتش في شاشة الصلاحيات خالص — يعني ماكانش ينفع الأدمن
       يديها لحد.

   دلوقتي المصدر جدول app_pages (key, file, title, section, sort_order,
   badge, is_active)، والصلاحيات مربوطة بـpage_key الثابت بدل اسم الملف
   (تغيير اسم ملف كان بيضيّع صلاحياته بصمت).

   ⚠️ لازم يتحمّل بعد config.js.
   ═══════════════════════════════════════════════════════════════════ */

const Pages = (function () {

  const CACHE_KEY = 'phalix_pages_v1';

  let _list = [];
  let _ready = null;
  const _subs = [];

  function _norm(rows) {
    return (rows || [])
      .filter(p => p && p.key && p.file)
      .map(p => ({
        key:     String(p.key),
        file:    String(p.file),
        title:   String(p.title || p.key),
        section: String(p.section || ''),
        badge:   p.badge || null,
        sort:    p.sort_order == null ? 999 : p.sort_order
      }))
      .sort((a, b) => a.sort - b.sort);
  }

  try {
    const c = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
    if (c && c.length) _list = _norm(c);
  } catch (e) {}

  function _apply(rows) {
    const n = _norm(rows);
    if (!n.length) return false;
    _list = n;
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(n)); } catch (e) {}
    _subs.forEach(fn => { try { fn(_list); } catch (e) {} });
    return true;
  }

  function load(force) {
    if (_ready && !force) return _ready;
    _ready = (async function () {
      try {
        const r = await fetch(
          `${PHALIX_CONFIG.supabaseUrl}/rest/v1/app_pages` +
          `?select=key,file,title,section,sort_order,badge&is_active=eq.true&order=sort_order`,
          { headers: { apikey: PHALIX_CONFIG.supabaseAnonKey,
                       Authorization: 'Bearer ' + PHALIX_CONFIG.supabaseAnonKey } });
        if (r.ok) _apply(await r.json());
      } catch (e) {}
      return _list;
    })();
    return _ready;
  }

  const ready = () => load();
  function onChange(fn) { if (typeof fn === 'function') { _subs.push(fn); fn(_list); } }

  const all     = () => _list.slice();
  const byKey   = k => _list.find(p => p.key === String(k || '').trim()) || null;
  /* الملف ممكن ييجي بـquery string (employees.html → customers.html?tab=…) */
  const byFile  = f => {
    const s = String(f || '').trim();
    return _list.find(p => p.file === s) ||
           _list.find(p => p.file.split('?')[0] === s.split('?')[0]) || null;
  };

  /* الاسم المعروض لأي شاشة — بالمفتاح أو باسم الملف */
  function title(x) {
    const p = byKey(x) || byFile(x);
    return p ? p.title : String(x || '');
  }
  function section(x) {
    const p = byKey(x) || byFile(x);
    return p ? p.section : '';
  }
  function keyOf(fileOrKey) {
    const p = byKey(fileOrKey) || byFile(fileOrKey);
    return p ? p.key : null;
  }
  function fileOf(keyOrFile) {
    const p = byKey(keyOrFile) || byFile(keyOrFile);
    return p ? p.file : String(keyOrFile || '');
  }

  /* المجموعات بترتيب ظهورها في الكتالوج (sort_order بيحدّده) */
  function sections() {
    const seen = [];
    _list.forEach(p => { if (p.section && seen.indexOf(p.section) < 0) seen.push(p.section); });
    return seen;
  }
  /* { 'المجموعة': [صفحات...] } — للقائمة وشاشة الصلاحيات مع بعض */
  function grouped(filterFn) {
    const g = {};
    _list.forEach(p => {
      if (filterFn && !filterFn(p)) return;
      (g[p.section] = g[p.section] || []).push(p);
    });
    return g;
  }

  /* اسم الشاشة الحالية */
  const current = () => byFile((location.pathname.split('/').pop() || '').split('?')[0]);

  load();

  return { all, byKey, byFile, title, section, keyOf, fileOf,
           sections, grouped, current, load, ready, onChange };
})();
