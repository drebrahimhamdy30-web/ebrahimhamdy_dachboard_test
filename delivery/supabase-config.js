const SUPABASE_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';

const { createClient } = supabase;
const _authJwt = localStorage.getItem('authJwt');
const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: { headers: _authJwt ? { Authorization: 'Bearer ' + _authJwt } : {} }
});

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
