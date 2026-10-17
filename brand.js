/* ═══════════════════════════════════════════════════════════════════
   هوية Phalix (White-label) — الاسم والشعار والألوان من org_settings
   ═══════════════════════════════════════════════════════════════════
   الكتلة دي كانت متكررة **حرفيًا** في 3 ملفات: api.js (للـERP)،
   delivery/supabase-config.js، و delivery/app.html — يعني أي تعديل
   في الهوية لازم يتعمل 3 مرات.

   الفروع اتشالت من هنا خالص: مصدرها بقى جدول branches عبر branches.js
   (org_settings.branches كان بيدّي الأسماء والأسماء البديلة بس، من غير
   id ولا كود مختصر).

   ⚠️ لازم يتحمّل بعد config.js.
   ═══════════════════════════════════════════════════════════════════ */

(function () {
  /* ── اشتقاق الدرجات ───────────────────────────────────────────
     المستخدم بيختار **لون واحد لكل عائلة** من إعدادات المؤسسة،
     والدرجات (غامق/خلفية/خلفية فاتحة) بتتحسب منه. كده التحكم من
     مكان واحد فعلًا، مش ١٥ خانة لون.
     نفس معادلات org_settings.html — تعريف واحد للسلوك. */
  function hx(h) {
    h = String(h || '').replace('#', '');
    if (h.length === 3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
    return [parseInt(h.slice(0,2),16), parseInt(h.slice(2,4),16), parseInt(h.slice(4,6),16)];
  }
  function toHex(r_, g_, b_) {
    function p(v) { v = Math.max(0, Math.min(255, Math.round(v))); return ('0'+v.toString(16)).slice(-2); }
    return '#' + p(r_) + p(g_) + p(b_);
  }
  function darken(h, a)  { var c = hx(h); return toHex(c[0]*(1-a), c[1]*(1-a), c[2]*(1-a)); }
  function lighten(h, a) { var c = hx(h); return toHex(c[0]+(255-c[0])*a, c[1]+(255-c[1])*a, c[2]+(255-c[2])*a); }
  function ok(h) { return /^#?[0-9a-fA-F]{6}$/.test(String(h || '').trim()); }

  /* كل عائلة: التوكنز اللي بتاخد الأساس، والغامق، والخلفيات.
     الأسماء دي هي اللي الشاشات بتستعملها فعلًا بعد تحويل الألوان
     الثابتة — فأي لون جديد هنا بيوصل كل الشاشات على طول. */
  var FAMILIES = [
    { key: 'color_ok',     base: ['ok', 'success', 'ok-200'],
      dark: ['ok-strong'], bg: ['ok-bg'], soft: ['ok-bg-soft'] },
    { key: 'color_danger', base: ['danger-600', 'danger', 'red-light', 'danger-200'],
      dark: ['danger-strong'], bg: ['danger-bg'], soft: ['danger-bg-soft'] },
    { key: 'color_warn',   base: ['warn', 'warning', 'warn-600', 'warn-200'],
      dark: ['warn-strong', 'warn-text'], bg: ['warn-bg'], soft: ['warn-100'] },
    { key: 'color_info',   base: ['info', 'info-600', 'info-700', 'info-800'],
      dark: ['info-strong', 'info-900'], bg: ['info-bg'], soft: ['info-100'] }
  ];

  function applyFamily(r, base, fam) {
    if (!ok(base)) return;
    var d = darken(base, 0.18), bg = lighten(base, 0.85), soft = lighten(base, 0.94);
    fam.base.forEach(function (t) { r.setProperty('--' + t, base); });
    fam.dark.forEach(function (t) { r.setProperty('--' + t, d); });
    fam.bg.forEach(function (t)   { r.setProperty('--' + t, bg); });
    fam.soft.forEach(function (t) { r.setProperty('--' + t, soft); });
  }

  function apply(b) {
    if (!b) return;
    var r = document.documentElement.style;
    if (b.brand_primary)       { r.setProperty('--primary', b.brand_primary); r.setProperty('--accent', b.brand_primary); r.setProperty('--brand', b.brand_primary); }
    if (b.brand_primary_dark)  { r.setProperty('--primary-dark', b.brand_primary_dark); r.setProperty('--accent-dark', b.brand_primary_dark); r.setProperty('--brand-dark', b.brand_primary_dark); }
    if (b.brand_primary_light) { r.setProperty('--primary-light', b.brand_primary_light); r.setProperty('--brand-light', b.brand_primary_light); }
    /* لون ملاحظات التحويل. فاضي = الشاشة بترجع للون الهوية الغامق
       عبر var(--note-color, var(--accent-dark)) — مش بترجع أحمر. */
    if (b.brand_note)          r.setProperty('--note-color', b.brand_note);

    /* ألوان الحالة — فاضي = التوكن بيفضل على قيمته في tokens.css */
    FAMILIES.forEach(function (f) { applyFamily(r, b[f.key], f); });

    function els() {
      if (b.company_name) document.querySelectorAll('[data-org-name]').forEach(function (e) { e.textContent = b.company_name; });
      if (b.logo_url)     document.querySelectorAll('[data-org-logo]').forEach(function (e) { e.src = b.logo_url; });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', els); else els();
  }

  // من الكاش فورًا (مفيش وميض ألوان)، وبعدين تحديث من الخادم
  try { apply(JSON.parse(localStorage.getItem('orgBrand') || 'null')); } catch (e) {}
  try {
    fetch(PHALIX_CONFIG.supabaseUrl + '/rest/v1/org_settings?select=*&id=eq.1',
          { headers: { apikey: PHALIX_CONFIG.supabaseAnonKey,
                       Authorization: 'Bearer ' + PHALIX_CONFIG.supabaseAnonKey } })
      .then(function (r) { return r.json(); })
      .then(function (a) {
        if (a && a[0]) { apply(a[0]); try { localStorage.setItem('orgBrand', JSON.stringify(a[0])); } catch (e) {} }
      })
      .catch(function () {});
  } catch (e) {}
})();
