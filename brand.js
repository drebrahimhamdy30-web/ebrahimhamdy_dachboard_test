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

  /* كل عائلة: التوكنز اللي بتاخد كل درجة.
     ⚠️ الدرجة لازم تطابق **دور** التوكن الحقيقي. غلطة سابقة: حطّيت
     `--red-light` و`--danger-200` و`--ok-200` في مجموعة «الأساس»،
     فاختيار لون خطر كان هيخلي خلفية زر «عاجل» حمرا غامقة ونصه أحمر
     غامق = مش مقروء. دي خلفيات فاتحة مش ألوان أساس.
     الأسماء دي هي اللي الشاشات بتستعملها فعلًا بعد تحويل الألوان
     الثابتة — فأي لون جديد هنا بيوصل كل الشاشات على طول.
     ملاحظة: `--green-light` و`--yellow-light` و`--blue-light` معرّفة في
     delivery/delivery-style.css وهي خلفيات أزرار شاشة التوزيع — مضافة
     هنا عشان الأزرار تتبع الإعدادات زي باقي النظام. */
  var FAMILIES = [
    { key: 'color_ok',
      base: ['ok', 'success'],            dark: ['ok-strong'],
      mid:  ['ok-200'],
      bg:   ['ok-bg', 'green-light'],     soft: ['ok-bg-soft'] },

    { key: 'color_danger',
      base: ['danger-600', 'danger'],     dark: ['danger-strong'],
      mid:  ['danger-200'],
      bg:   ['danger-bg', 'red-light'],   soft: ['danger-bg-soft'] },

    { key: 'color_warn',
      base: ['warn', 'warning'],          dark: ['warn-strong', 'warn-text', 'warn-600'],
      mid:  ['warn-200'],
      bg:   ['warn-bg', 'yellow-light'],  soft: ['warn-100'] },

    /* التركوازي بس. التوكنز `--info-600/700/800/900/100` **أزرق** مش
       تركوازي — لو ضمّيتها هنا كان اختيار لون المعلومة هيقلب كل الأزرق
       في النظام تركوازي. سايبها ثابتة لحد ما يبقى ليها إعداد خاص. */
    { key: 'color_info',
      base: ['info'],                     dark: ['info-strong'],
      mid:  [],
      bg:   ['info-bg'],                  soft: ['blue-light'] }
  ];

  /* نسبة التباين (WCAG). محتاجينها عشان نضمن إن النص الغامق يفضل
     مقروء على الخلفية الفاتحة مهما كان اللون اللي المالك يختاره. */
  function relLum(h) {
    var c = hx(h).map(function (v) {
      v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function contrast(a, b) {
    var l1 = relLum(a), l2 = relLum(b);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  }

  /* الدرجة الغامقة بتتعمّق لحد ما التباين على الخلفية يعدّي 4.5.
     التعميق الثابت (0.18) كان بيدّي 3.6–4.3 لبعض العائلات — أقل من
     الألوان المختارة بالإيد (4.6–5.3)، يعني تراجع في القراءة. */
  /* معامل واحد بقصد: الخلفية بتتحسب جوّه. لما كانت بتتاخد من بره
     كان ممكن تتنادى بمعامل واحد فتبقى undefined، والتباين NaN،
     والحلقة ماتلفّش — يعني الحارس يعدّي وهو مش شغّال. */
  function darkFor(base) {
    var bg = lighten(base, 0.85), a = 0.18, d = darken(base, a);
    while (contrast(d, bg) < 4.5 && a < 0.75) { a += 0.05; d = darken(base, a); }
    return d;
  }

  function applyFamily(r, base, fam) {
    if (!ok(base)) return;
    var bg = lighten(base, 0.85);
    var sh = {
      base: base,
      dark: darkFor(base),
      mid:  lighten(base, 0.70),
      bg:   bg,
      soft: lighten(base, 0.94)
    };
    ['base', 'dark', 'mid', 'bg', 'soft'].forEach(function (k) {
      (fam[k] || []).forEach(function (t) { r.setProperty('--' + t, sh[k]); });
    });
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
