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
  function apply(b) {
    if (!b) return;
    var r = document.documentElement.style;
    if (b.brand_primary)       { r.setProperty('--primary', b.brand_primary); r.setProperty('--accent', b.brand_primary); }
    if (b.brand_primary_dark)  { r.setProperty('--primary-dark', b.brand_primary_dark); r.setProperty('--accent-dark', b.brand_primary_dark); }
    if (b.brand_primary_light) r.setProperty('--primary-light', b.brand_primary_light);

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
