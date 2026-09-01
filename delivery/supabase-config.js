const SUPABASE_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';

const { createClient } = supabase;

// ⚠️ atob لوحده بيخرّب اسم الفرع العربي جوه التوكن
function sbDecodeJwt(t) {
  try {
    return JSON.parse(decodeURIComponent(escape(atob(
      t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')))));
  } catch (e) { return null; }
}
function sbJwtValid(t) {
  const p = t && sbDecodeJwt(t);
  return !!(p && p.exp && p.exp * 1000 > Date.now() + 60000);
}

// توكن Supabase عمره ساعة. الصفحات دي بتفضل مفتوحة ساعات (التوزيع مثلًا)، وقبل كده
// كان التوكن بيتاخد وقت التحميل بس وبعد ساعة كل النداءات تبقى 401 والمستخدم يتطلّع.
// نجدّده استباقيًا كل 10 دقايق وبنبعت دايمًا آخر توكن مخزّن مش نسخة وقت التحميل.
let _sbRefreshInFlight = null;   // تجديد واحد بس مهما كان عدد النداءات المتوازية
async function sbRefreshSession() {
  if (localStorage.getItem('authProvider') !== 'supabase') return false;
  if (sbJwtValid(localStorage.getItem('authJwt'))) return true;
  if (_sbRefreshInFlight) return _sbRefreshInFlight;
  _sbRefreshInFlight = _sbGuardedRefresh().finally(() => { _sbRefreshInFlight = null; });
  return _sbRefreshInFlight;
}

// قفل على مستوى الأصل كله: app.html والـiframe جوّاه وأي تبويب تاني ما يجدّدوش مع بعض.
// Supabase بيلغي الـrefresh token مع كل استعمال — فلو سياقين بعتوه في نفس اللحظة،
// واحد ينجح والتاني ياخد "Already Used" ويقع بـ«خطأ في التحميل».
async function _sbGuardedRefresh() {
  if (navigator.locks && navigator.locks.request) {
    return navigator.locks.request('phalix-sb-refresh', async () => {
      if (sbJwtValid(localStorage.getItem('authJwt'))) return true;   // حد تاني جدّد وإحنا مستنيين
      return _sbDoRefresh();
    });
  }
  return _sbDoRefresh();
}

async function _sbDoRefresh() {
  const rt = localStorage.getItem('sbRefresh');
  if (!rt) return false;
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: SUPABASE_KEY },
      body: JSON.stringify({ refresh_token: rt })
    });
    const d = await r.json();
    // فشل التجديد مش معناه بالضرورة خروج: ممكن سياق تاني يكون جدّد وحرق التوكن —
    // لو التخزين بقى فيه توكن صالح يبقى إحنا تمام.
    if (!r.ok || !d.access_token) return sbJwtValid(localStorage.getItem('authJwt'));
    localStorage.setItem('authJwt',   d.access_token);
    localStorage.setItem('authToken', d.access_token);
    if (d.refresh_token) localStorage.setItem('sbRefresh', d.refresh_token);
    return true;
  } catch (e) { return sbJwtValid(localStorage.getItem('authJwt')); }
}

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
      let t = localStorage.getItem('authJwt');
      if (t && !sbJwtValid(t)) { await sbRefreshSession(); t = localStorage.getItem('authJwt'); }
      if (!t || !sbJwtValid(t)) return fetch(url, options);
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
