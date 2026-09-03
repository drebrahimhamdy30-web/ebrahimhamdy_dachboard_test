/* ═══════════════════════════════════════════════════════════════════
   جلسة Phalix — المصدر الوحيد لهوية المستخدم والدور والفرع والخروج
   ═══════════════════════════════════════════════════════════════════
   قبل الملف ده كان فيه 3 تنفيذات مختلفة للجلسة (api.js للـERP،
   delivery/permissions.js، وdelivery/app.html) وكل واحد بيعرف مفاتيح
   مختلفة — فالخروج من الشل كان بيسيب authJwt و sbRefresh على الجهاز
   والجلسة تفضل قابلة للتجديد بعد ما المستخدم «خرج».

   دلوقتي قائمة المفاتيح متعرّفة مرة واحدة (Session.KEYS) والخروج بيمسحها
   كلها، وأي شاشة بتقرأ الهوية من Session.user() بدل localStorage مباشرة.

   ⚠️ لازم يتحمّل بعد config.js:
       <script src="config.js?v=..."></script>
       <script src="session.js?v=..."></script>
   ═══════════════════════════════════════════════════════════════════ */

const Session = (function () {

  /* ── كل مفاتيح الجلسة في مكان واحد ────────────────────────────────
     أي مفتاح جديد يتضاف هنا بس — والخروج بيمسحه تلقائيًا.          */
  const KEYS = [
    'authToken', 'authJwt', 'sbRefresh', 'authProvider',
    'activeUser', 'fullName', 'userRole',
    'userBranch', 'userBranchId',
    'legacyId', 'userDbId',
    'loginTime', 'lastVerify'
  ];

  /* اتحاد الأدوار الموجودة في branch_users (مستخدمين فعليين) و
     page_permissions (صفوف صلاحيات) — الجدولين مش متطابقين:
       • supervisor  → له صفوف صلاحيات لكن مفيش مستخدم بالدور ده
       • driver      → 54 مستخدم لكن مفيش صفوف صلاحيات (بيدخلوا driver.html
                       اللي مابيسألش page_permissions أصلًا)                */
  const ROLES = ['admin', 'manager', 'supervisor', 'pharmacist', 'cashier',
                 'accountant', 'reviewer', 'inventory', 'employee', 'driver'];

  let _permCache = null;   // كاش صلاحيات الدور — بيتصفّر مع أي تغيير مستخدم

  const get = k => { try { return localStorage.getItem(k); } catch (e) { return null; } };
  const set = (k, v) => { try { localStorage.setItem(k, v == null ? '' : String(v)); } catch (e) {} };

  /* ── الدور: تطبيع ────────────────────────────────────────────────
     الـbackend كان بيرجّع 'manger' بغلطة إملائية في وقت من الأوقات،
     وصفحة واحدة بس (customers) هي اللي كانت بتتعامل معاها — يعني نفس
     المستخدم كان يعدّي في شاشة ويتمنع في شاشة. التطبيع هنا يخلّي كل
     الشاشات تشوف نفس الدور.

     دور مش في ROLES بيعدّي زي ما هو (مابنحوّلوش لـemployee): كده أي دور
     جديد يتضاف في القاعدة مايتمنحش صلاحيات employee بالغلط — هو ببساطة
     مايطابقش أي فحص فمايشوفش حاجة لحد ما يتضاف هنا وفي page_permissions. */
  function normRole(r) {
    const v = String(r || '').trim().toLowerCase();
    if (v === 'manger') return 'manager';
    return ROLES.includes(v) ? v : (v || 'employee');
  }

  /* ── قراءة الجلسة ─────────────────────────────────────────────── */
  function user() {
    const token = get('authToken');
    const username = get('activeUser');
    if (!token || !username) return null;
    return {
      id:        get('userDbId') || null,
      legacyId:  get('legacyId') || null,
      username:  username,
      full_name: get('fullName') || username,
      role:      normRole(get('userRole')),
      branch:    get('userBranch') || '',
      branch_id: get('userBranchId') || null,
      provider:  get('authProvider') || 'n8n'
    };
  }

  const isLoggedIn = () => !!user();
  const role       = () => normRole(get('userRole'));
  const branch     = () => get('userBranch') || '';
  const branchId   = () => get('userBranchId') || null;
  const username   = () => get('activeUser') || '';
  const fullName   = () => get('fullName') || get('activeUser') || '';

  /* is('admin','manager') — بديل مقروء لسلاسل === المتكررة */
  function is() {
    const r = role();
    for (let i = 0; i < arguments.length; i++)
      if (normRole(arguments[i]) === r) return true;
    return false;
  }
  const isAdmin = () => is('admin');

  /* ── فكّ التوكن وفحص صلاحيته ─────────────────────────────────────
     ⚠️ atob لوحده بيخرّب اسم الفرع العربي جوه التوكن — لازم
     decodeURIComponent(escape(...)). ده كان مكرر في 3 ملفات.        */
  function decodeJwt(t) {
    try {
      return JSON.parse(decodeURIComponent(escape(atob(
        String(t).split('.')[1].replace(/-/g, '+').replace(/_/g, '/')))));
    } catch (e) { return null; }
  }
  function jwtValid(t, marginMs) {
    const p = t && decodeJwt(t);
    const m = marginMs == null ? 60000 : marginMs;
    return !!(p && p.exp && p.exp * 1000 > Date.now() + m);
  }
  const tokenValid = m => jwtValid(get('authJwt'), m);

  /* ── تجديد التوكن ────────────────────────────────────────────────
     ⚠️ ده كان مكتوب 5 مرات في المشروع (api.js، app.html، auth.html،
     supabase-config.js، shift_history.html) وتلاتة منهم من غير قفل.
     Supabase بيحرق الـrefresh token مع كل استعمال، فلو سياقين بعتوه
     في نفس اللحظة واحد ينجح والتاني ياخد «Already Used» ويقع —
     وده كان سبب «خطأ في التحميل» أثناء الشغل.

     التنفيذ الواحد ده بيحمي بتلات طبقات:
       1. تجميع النداءات المتوازية في نفس الصفحة (_inFlight)
       2. قفل Web Locks على مستوى الأصل كله (الشل + الـiframe + أي تبويب)
       3. إعادة فحص التوكن جوّه القفل — يمكن حد تاني جدّد وإحنا مستنيين
     وفشل التجديد مش معناه خروج: لو التخزين بقى فيه توكن صالح يبقى
     سياق تاني جدّد ونجح.                                            */
  let _inFlight = null;
  async function refresh(marginMs) {
    if (get('authProvider') !== 'supabase') return false;
    // الصلاحية الأول: توكن سليم = تمام حتى لو مفيش refresh token مخزّن
    if (tokenValid(marginMs)) return true;
    if (!get('sbRefresh')) return false;
    if (_inFlight) return _inFlight;
    _inFlight = _locked(marginMs).finally(() => { _inFlight = null; });
    return _inFlight;
  }

  async function _locked(marginMs) {
    const body = () => tokenValid(marginMs) ? Promise.resolve(true) : _doRefresh(marginMs);
    if (navigator.locks && navigator.locks.request)
      return navigator.locks.request('phalix-sb-refresh', body);
    return body();
  }

  async function _doRefresh(marginMs) {
    const rt = get('sbRefresh');
    if (!rt) return false;
    try {
      const r = await fetch(`${PHALIX_CONFIG.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: PHALIX_CONFIG.supabaseAnonKey },
        body: JSON.stringify({ refresh_token: rt })
      });
      const d = await r.json();
      if (!r.ok || !d.access_token) return tokenValid(marginMs);
      set('authJwt',   d.access_token);
      set('authToken', d.access_token);
      set('sbRefresh', d.refresh_token || rt);
      return true;
    } catch (e) { return tokenValid(marginMs); }
  }

  /* توكن صالح للاستعمال في هيدر Authorization — بيجدّد لو لزم.
     بيرجّع null لو مفيش، فالنداء يستعمل مفتاح anon (عرض فقط).      */
  async function validToken() {
    if (!tokenValid()) await refresh();
    const t = get('authJwt');
    return jwtValid(t) ? t : null;
  }

  /* ── كتابة الجلسة ────────────────────────────────────────────────
     صفحتَي الدخول (index.html و delivery/auth.html) كانتا بتكتبا نفس
     الـ11 مفتاح كل واحدة بطريقتها — أي مفتاح جديد كان لازم يتضاف في
     الاتنين والنسيان بيسيب شاشة بتقرأ فاضي.                        */
  /* ⚠️ مافيش رجوع لاسم المستخدم لو الفرع فاضي: ده كان بيخلّي userBranch
     يساوي اسم مستخدم، والشاشات اللي بتفلتر بالفرع تفلتر على اسم شخص
     فترجّع فاضي. اللي عايز الرجوع ده يبعته صريح في result.branch.     */
  function save(result) {
    if (!result) return null;
    set('activeUser', result.user || result.username);
    set('authToken',  result.token);
    set('authJwt',    result.jwt || '');
    set('userRole',   normRole(result.role || 'employee'));
    set('userBranch', result.branch || '');
    set('fullName',   result.full_name || result.user || result.username || '');
    set('legacyId',   result.legacy_id || '');
    set('userDbId',   result.id || '');
    set('loginTime',  Date.now());
    if (result.provider) set('authProvider', result.provider);
    if (result.refresh)  set('sbRefresh',    result.refresh);
    _permCache = null;          // مستخدم جديد = دور جديد = صلاحيات جديدة
    return user();
  }

  /* رقم الفرع: الشاشات بتفلتر بـbranch_id، والدخول بيدّي الاسم بس.
     كان الاستعلام ده متكرر حرفيًا في صفحتَي الدخول — ونسخة index.html
     كانت من غير مهلة، فلو Supabase بطيء الدخول يعلّق. المهلة 3 ثواني
     هنا معناها الدخول يكمل والـid يتجدّد بعدين بدل ما المستخدم يستنى.
     الأدمن مش مربوط بفرع فبنسيبه فاضي (زي التنفيذين القديمين).        */
  async function resolveBranchId() {
    const name = branch();
    if (!name || isAdmin()) { set('userBranchId', ''); return ''; }
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 3000);
      const r = await fetch(
        `${PHALIX_CONFIG.supabaseUrl}/rest/v1/branches?select=id&name=eq.${encodeURIComponent(name)}&limit=1`,
        { headers: { apikey: PHALIX_CONFIG.supabaseAnonKey,
                     Authorization: 'Bearer ' + PHALIX_CONFIG.supabaseAnonKey },
          signal: ctl.signal });
      clearTimeout(timer);
      const rows = r.ok ? await r.json() : [];
      const id = (rows && rows[0] && rows[0].id) || '';
      set('userBranchId', id);
      return id;
    } catch (e) { set('userBranchId', ''); return ''; }
  }

  /* ── الخروج ──────────────────────────────────────────────────────
     ⚠️ لازم يمسح authJwt و sbRefresh و authProvider كمان. من غير كده
     الجهاز يفضل شايل refresh token صالح، وsupabase-config.js بيفضل
     يجدّد بيه توكن للمستخدم اللي «خرج» — خطر حقيقي على أجهزة مشتركة
     زي الكاشير وتليفونات السواقين.                                 */
  function clear() {
    KEYS.forEach(k => { try { localStorage.removeItem(k); } catch (e) {} });
    try {
      sessionStorage.removeItem('delivery_last_page');
      sessionStorage.removeItem('delivery_last_title');
      sessionStorage.removeItem('jwtRefreshDone');
    } catch (e) {}
    _permCache = null;
  }

  /* الوجهة بتختلف: الشل والتوصيل بيرجّعوا لـauth.html، الـERP لـindex.html */
  function loginPage() {
    return /\/delivery\//.test(location.pathname) ? 'auth.html' : 'index.html';
  }
  function logout(to) {
    clear();
    window.location.href = to || loginPage();
  }

  /* ── صلاحيات الصفحات ─────────────────────────────────────────────
     get_role_pages بترجّع [{page, can_view, can_edit}] للدور.
     بنكاشها في الذاكرة عشان الصفحة ما تسألش أكتر من مرة.           */
  async function pages() {
    if (_permCache) return _permCache;
    try {
      const r = await fetch(`${PHALIX_CONFIG.supabaseUrl}/rest/v1/rpc/get_role_pages`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json',
                   apikey: PHALIX_CONFIG.supabaseAnonKey,
                   Authorization: 'Bearer ' + (get('authJwt') || PHALIX_CONFIG.supabaseAnonKey) },
        body: JSON.stringify({ p_role: role() })
      });
      _permCache = r.ok ? (await r.json()) || [] : [];
    } catch (e) { _permCache = []; }
    return _permCache;
  }

  /* مفتاح الصفحة في page_permissions = اسم الملف، مثلاً 'expenses.html'.
     can() من غير وسيط بتفترض الصفحة الحالية.
     can('supplier_balances.html') → { view:true, edit:false }         */
  function thisPage() {
    return (location.pathname.split('/').pop() || '').split('?')[0] || '';
  }
  async function can(page) {
    if (isAdmin()) return { view: true, edit: true };
    const key = page || thisPage();
    const p = (await pages()).find(x => x.page === key);
    return { view: !!(p && p.can_view), edit: !!(p && p.can_edit) };
  }

  /* ── حارس الصفحة ─────────────────────────────────────────────────
     require()                      → لازم يكون داخل
     require({roles:['admin']})     → ولازم دوره من دول
     require({page:'expenses'})     → ولازم يكون له can_view عليها
     بترجّع المستخدم، أو null وبتحوّل لصفحة الدخول.                 */
  async function require(opts) {
    const o = opts || {};
    const u = user();
    if (!u) { window.location.replace(o.redirect || loginPage()); return null; }
    if (o.roles && o.roles.length && !o.roles.map(normRole).includes(u.role)) {
      window.location.replace(o.redirect || loginPage()); return null;
    }
    if (o.page) {
      const c = await can(o.page);
      if (!c.view) { window.location.replace(o.redirect || loginPage()); return null; }
    }
    return u;
  }

  return { KEYS, ROLES, normRole, user, isLoggedIn, role, branch, branchId,
           username, fullName, is, isAdmin, decodeJwt, jwtValid, tokenValid,
           refresh, validToken,
           save, resolveBranchId, clear, logout, loginPage, thisPage,
           pages, can, require };
})();
