// الرابط والمفتاح بييجوا من config.js — لازم يتحمّل قبل الملف ده

const { createClient } = supabase;

// فكّ التوكن وفحص صلاحيته — التنفيذ في session.js (atob لوحده بيخرّب
// اسم الفرع العربي جوه التوكن فبيتفكّ بـdecodeURIComponent(escape(...))).
const sbDecodeJwt = Session.decodeJwt;
const sbJwtValid  = Session.jwtValid;

// توكن Supabase عمره ساعة. الصفحات دي بتفضل مفتوحة ساعات (التوزيع مثلًا)، وقبل كده
// كان التوكن بيتاخد وقت التحميل بس وبعد ساعة كل النداءات تبقى 401 والمستخدم يتطلّع.
// نجدّده استباقيًا كل 10 دقايق وبنبعت دايمًا آخر توكن مخزّن مش نسخة وقت التحميل.
// التجديد كله في session.js دلوقتي (نفس القفل ونفس المنطق) — كان مكرر
// هنا وفي api.js و app.html و auth.html و shift_history.html.
async function sbRefreshSession() { return Session.refresh(); }

// ⚠️ التوكن مش بيتحط في الهيدر الثابت خالص: الهيدر ده بيتاخد مرة واحدة وقت التحميل
// وبيفضل يتبعت حتى لو التوكن انتهى — فكل النداءات ترجع 401 والشاشة تفضل فاضية.
// الـfetch تحت هو اللي بيضيفه، ولو مش صالح مابيضيفوش فمفتاح anon يشتغل والعرض يفضل شغّال.
const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: {
    // كل نداء بياخد أحدث توكن من التخزين (بعد أي تجديد) بدل نسخة وقت التحميل.
    // ⚠️ لازم Headers() مش نشر بالـspread: supabase-js بيبعت الهيدرات كـHeaders instance،
    // و{...headers} عليها بيدّي {} فالـapikey بيضيع والنتيجة "No API key found in request".
    // التوكن يُستعمل بس لو لسه صالح — لو منتهي نسيب مفتاح anon يشتغل فالعرض مايقعش
    // بدل ما كل نداء يرجع 401.
    // لو التوكن منتهي بنستنى التجديد يخلص الأول. الرجوع لمفتاح anon مش كفاية هنا:
    // سياسة orders بتدي anon صفر صفوف، فالشاشة كانت بتفضل فاضية من غير أي رسالة خطأ.
    fetch: async (url, options = {}) => {
      const t = await Session.validToken();
      if (!t) return fetch(url, options);
      const h = new Headers(options.headers || {});
      h.set('Authorization', 'Bearer ' + t);
      return fetch(url, { ...options, headers: h });
    }
  }
});

sbRefreshSession();
setInterval(sbRefreshSession, 10 * 60 * 1000);

// ===== الهوية (White-label): تطبيق من الكاش فورًا + تحديث من org_settings =====
(function () {
  function setBrand(b) {
    if (!b) return;
    var r = document.documentElement.style;
    if (b.brand_primary)       { r.setProperty('--primary', b.brand_primary); r.setProperty('--accent', b.brand_primary); }
    if (b.brand_primary_dark)  { r.setProperty('--primary-dark', b.brand_primary_dark); r.setProperty('--accent-dark', b.brand_primary_dark); }
    if (b.brand_primary_light) r.setProperty('--primary-light', b.brand_primary_light);
    if (b.branches && b.branches.length) {
      window.ORG_BRANCHES = b.branches.map(function (x) { return x.name; });
      var am = {}; b.branches.forEach(function (x) { am[x.name] = x.name; (x.aliases || []).forEach(function (a) { am[a] = x.name; }); });
      window.ORG_BRANCH_ALIAS = am;
    }
    function els() {
      if (b.company_name) document.querySelectorAll('[data-org-name]').forEach(function (e) { e.textContent = b.company_name; });
      if (b.logo_url)     document.querySelectorAll('[data-org-logo]').forEach(function (e) { e.src = b.logo_url; });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', els); else els();
  }
  window.orgBranchAlias = function (raw) { return (window.ORG_BRANCH_ALIAS && window.ORG_BRANCH_ALIAS[String(raw == null ? '' : raw).trim()]) || raw; };
  try { setBrand(JSON.parse(localStorage.getItem('orgBrand') || 'null')); } catch (e) {}
  try {
    db.from('org_settings').select('*').eq('id', 1).maybeSingle().then(function (res) {
      if (res && res.data) { setBrand(res.data); try { localStorage.setItem('orgBrand', JSON.stringify(res.data)); } catch (e) {} }
    });
  } catch (e) {}
})();
