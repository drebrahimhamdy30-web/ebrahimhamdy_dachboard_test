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
  /* ── انتهاء الجلسة: رسالة بدل شاشة فاضية ────────────────────────
     قبل إغلاق anon، أي نداء بتوكن منتهي كان بيرجع لمفتاح anon ويشتغل،
     فالمستخدم مايحسّش. بعد الإغلاق، نفس المسار بيدّي **401 صامت**
     والشاشة تبان فاضية والمستخدم يفتكر إن مفيش بيانات.
     (حصل فعلًا 2026-09-04 مع حساب محاسب: جدار 401 في الكونسول وجدول
     فاضي من غير أي رسالة.)

     ⚠️ الشرط `authProvider === 'supabase'` مهم: من غيره البانر هيظهر
        على صفحة الدخول نفسها — هناك مفيش توكن **بقصد**.                */
  let _expiredShown = false;
  function _sessionExpired() {
    if (_expiredShown) return;
    // على صفحة الدخول نفسها مفيش معنى للبانر — ده مكان تسجيل الدخول
    const _p = location.pathname;
    if (/(^|\/)(index|auth)\.html?$/.test(_p) || _p.charAt(_p.length - 1) === '/') return;
    _expiredShown = true;
    try {
      const d = document.createElement('div');
      d.setAttribute('role', 'alert');
      d.style.cssText = 'position:fixed;inset:0;z-index:2147483647;display:flex;'
        + 'align-items:center;justify-content:center;background:rgba(15,23,42,.72);'
        + 'font-family:Cairo,sans-serif;direction:rtl';
      d.innerHTML =
        '<div style="background:#fff;color:#0f172a;max-width:340px;width:86%;padding:26px 22px;'
        + 'border-radius:16px;text-align:center;box-shadow:0 20px 50px rgba(0,0,0,.35)">'
        + '<div style="font-size:38px;line-height:1;margin-bottom:12px">\u23F1\uFE0F</div>'
        + '<div style="font-weight:700;font-size:1.05rem;margin-bottom:6px">انتهت الجلسة</div>'
        + '<div style="color:#64748b;font-size:.9rem;line-height:1.7;margin-bottom:18px">'
        + 'مدة الدخول خلصت، فالبيانات مش هتظهر.<br>سجّل دخول تاني وكمّل عادي.</div>'
        + '<button id="_sxBtn" style="background:#0d9488;color:#fff;border:0;border-radius:10px;'
        + 'padding:11px 26px;font-family:inherit;font-size:.95rem;font-weight:700;cursor:pointer">'
        + 'تسجيل الدخول</button></div>';
      const go = () => {
        // ⚠️ لازم نمسح الجلسة الأول: من غير كده صفحة الدخول نفسها بتلاقي
        //    authProvider='supabase' وتوكن منتهي، فالبانر يظهر عليها تاني
        //    والمستخدم يفضل يلف في دايرة من غير ما يوصل لحاجة.
        try { clear(); } catch (e) {}
        // النافذة الأصلية مش الإطار، والمسار نسبي لموقعها عشان يشتغل على
        // أي دومين أو مجلد فرعي.
        let loc;
        try { loc = (window.top !== window.self) ? window.top.location : location; }
        catch (e) { loc = location; }
        const file = loc.pathname.indexOf('/delivery/') >= 0 ? 'auth.html' : 'index.html';
        let href; try { href = new URL(file, loc.href).href; } catch (e) { href = file; }
        try { loc.replace(href); } catch (e) { window.location.replace(href); }
      };
      d.addEventListener('click', ev => { if (ev.target && ev.target.id === '_sxBtn') go(); });
      (document.body || document.documentElement).appendChild(d);
    } catch (e) { /* لو الـDOM لسه مش جاهز، الرجوع لـanon بيفضل زي ما هو */ }
  }

  async function validToken() {
    if (!tokenValid()) await refresh();
    const t = get('authJwt');
    if (jwtValid(t)) return t;
    // كان مسجّل دخول والتجديد فشل = جلسة منتهية فعلًا، مش زائر
    if (get('authProvider') === 'supabase') _sessionExpired();
    return null;
  }

  /* ── ترويسات PostgREST للجداول المقفولة ─────────────────────────
     الجداول المالية (contracts / sales_items / erp_expenses /
     pos_shifts / pos_wallet_transfers / wallet) بتتقفل على anon، يعني
     لازم النداء يتبعت بتوكن المستخدم. الدوال دي بتجيب توكن صالح
     (وبتجدّده لو لزم) وبترجع لمفتاح anon لو مفيش — عشان صفحة عرض
     لمستخدم خارج الجلسة ماتقعش كلها، بس الكتابة هتترفض من السيرفر.

     ⚠️ استدعيها **قبل كل نداء** مش مرة واحدة عند التحميل: التوكن
     بيخلص بعد ساعة، والترويسة المتخزّنة وقت الإنشاء بتفضل بالقديم
     فكل حاجة ترجّع 401 من غير سبب واضح.                            */
  async function bearer() {
    return (await validToken()) || PHALIX_CONFIG.supabaseAnonKey;
  }
  async function headers(prefer) {
    const h = { 'Content-Type': 'application/json',
                apikey: PHALIX_CONFIG.supabaseAnonKey,
                Authorization: 'Bearer ' + (await bearer()) };
    if (prefer) h.Prefer = prefer;
    return h;
  }
  /* عميل supabase-js متسلّح بتوكن المستخدم.
     ⚠️ **ماتعدّلش `db.rest.headers` بعد الإنشاء** — supabase-js v2 بيحسب
        ترويسة Authorization لكل نداء من خيار `accessToken`، والتعديل
        اليدوي بيتجاهَل **بصمت**: الصفحة تفضل تبعت مفتاح anon وانت فاكرها
        بقت authenticated. (متأكد بالتجربة على الموقع الحي 2026-09-04:
        السنتينل اللي اتحط في db.rest.headers ماظهرش في النداء خالص،
        وخيار accessToken ظهر فورًا.)
     الدالة بتترجع لمفتاح anon لو مفيش توكن — عشان صفحة العرض ماتقعش. */
  function client(extra) {
    return supabase.createClient(PHALIX_CONFIG.supabaseUrl, PHALIX_CONFIG.supabaseAnonKey,
      Object.assign({ auth: { persistSession: false, autoRefreshToken: false },
                      accessToken: () => bearer() }, extra || {}));
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
    _tabCache = null;
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
    _tabCache = null;
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

  /* can() بتقبل المفتاح الثابت ('supplier_balances') أو اسم الملف
     ('supplier_balances.html')، ومن غير وسيط بتفترض الصفحة الحالية.
     get_role_pages بترجّع الاتنين فالمقارنة بتنجح مع أي شكل.          */
  function thisPage() {
    return (location.pathname.split('/').pop() || '').split('?')[0] || '';
  }
  async function can(page) {
    if (isAdmin()) return { view: true, edit: true };
    const q = String(page || thisPage()).trim();
    const p = (await pages()).find(x => x.key === q || x.page === q);
    return { view: !!(p && p.can_view), edit: !!(p && p.can_edit) };
  }

  /* ── صلاحيات التبويبات جوّه الشاشة ─────────────────────────────────
     get_role_tabs بترجّع كل تبويبات الشاشات المسجّلة في app_page_tabs مع
     allowed للدور (مفيش صف منع = مسموح، والأدمن دايمًا مسموح).
     guardTabs('key') بتتنادى مرة في آخر الشاشة:
       • بتحط CSS بيخفي أزرار التبويبات الممنوعة — حتى اللي بتترسم بعدين
         (زي تبويبات أرصدة الموردين اللي بتتبني مع كل render).
       • لو التبويب المفتوح أو الافتراضي ممنوع، بتضغط أول تبويب مسموح.
     ⚠️ ده إخفاء في الواجهة زي صلاحيات الصفحات؛ حماية البيانات نفسها في
        RPCs كل شاشة.                                                  */
  let _tabCache = null;
  async function tabRules() {
    if (_tabCache) return _tabCache;
    try {
      const r = await fetch(`${PHALIX_CONFIG.supabaseUrl}/rest/v1/rpc/get_role_tabs`, {
        method: 'POST', headers: await headers(), body: JSON.stringify({ p_role: role() })
      });
      _tabCache = r.ok ? (await r.json()) || [] : [];
    } catch (e) { _tabCache = []; }
    return _tabCache;
  }
  async function tabAllowed(pageKey, tabKey) {
    if (isAdmin()) return true;
    const t = (await tabRules()).find(x => x.page_key === pageKey && x.tab_key === tabKey);
    return !t || t.allowed !== false;
  }
  async function guardTabs(pageKey) {
    if (isAdmin()) return new Set();
    const rows = (await tabRules()).filter(x => x.page_key === pageKey)
                                   .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));
    const denied = rows.filter(x => x.allowed === false);
    if (!denied.length) return new Set();

    const st = document.createElement('style');
    st.setAttribute('data-tab-guard', pageKey);
    st.textContent = denied.map(x => x.selector.split(',').map(sel => sel.trim() + '{display:none!important}').join('\n')).join('\n');
    document.head.appendChild(st);

    const allowed = rows.filter(x => x.allowed !== false);
    const defaultDenied = rows.length && rows[0].allowed === false;
    const visible = el => el && getComputedStyle(el).display !== 'none';
    const tryPick = () => {
      let deniedEls = [];
      denied.forEach(x => { try { deniedEls = deniedEls.concat([...document.querySelectorAll(x.selector)]); } catch (e) {} });
      if (!deniedEls.length) return false;                       // الأزرار لسه ماترسمتش
      const activeDenied = deniedEls.some(el => el.classList.contains('active'));
      if (!activeDenied && !defaultDenied) return true;
      for (const x of allowed) {
        let el = null;
        try { el = [...document.querySelectorAll(x.selector)].find(visible); } catch (e) {}
        if (el) { el.click(); return true; }
      }
      return false;
    };
    let n = 0;
    (function tick() { if (tryPick() || ++n > 40) return; setTimeout(tick, 150); })();
    return new Set(denied.map(x => x.tab_key));
  }


  /* ═══════════════ طبقة جلب البيانات — سقف الـ1000 ═══════════════
     PostgREST بيقص أي رد عند 1000 صف (db-max-rows)، والقص بيحصل **بعد**
     الفلترة والترتيب — يعني «أحدث 1000» وخلاص، واللي أقدم بيختفي من غير
     أي رسالة خطأ. و`limit=5000` وهم: بيرجّع 1000 برضه (اتجرّب على
     customers: 21,356 صف والرد 1000 بالظبط).

     القاعدة: أي شرط المستخدم بيختاره لازم يروح للسيرفر في الـURL — القاعدة
     بتفحص كل الصفوف بالفهارس وترجّع النتيجة، والسقف بيتطبّق على النتيجة.
     الفلترة في المتصفح بتشتغل على اللي وصل بس، فبتضيّع بيانات بصمت.

     لما النتيجة نفسها أكبر من 1000، استعمل getAll() — بتلفّ بالـoffset
     لحد ما تخلص، وبترجّع مع الصفوف:
        rows.total       العدد الحقيقي من هيدر Content-Range
        rows.incomplete  true لو حصل قص أو فشل نص الطريق                */
  const MAX_ROWS = 1000;

  function _withRange(path, limit, offset) {
    const sep = path.indexOf('?') >= 0 ? '&' : '?';
    return path + sep + 'limit=' + limit + '&offset=' + offset;
  }
  // «0-999/21356» → 21356 (بيرجع null لو السيرفر ماقالش العدد)
  function _totalFrom(res) {
    const cr = res.headers.get('content-range') || '';
    const m = cr.match(/\/(\d+)\s*$/);
    return m ? parseInt(m[1], 10) : null;
  }

  /* نداء واحد بصفحة محدّدة. opts: {limit, offset, count, method, body} */
  async function fetchPage(path, opts) {
    const o = opts || {};
    const lim = Math.min(o.limit || MAX_ROWS, MAX_ROWS);
    const h = await headers(o.count ? 'count=exact' : null);
    const url = PHALIX_CONFIG.supabaseUrl + '/rest/v1/' + _withRange(path, lim, o.offset || 0);
    const init = { method: o.method || 'GET', headers: h };
    if (o.body != null) init.body = typeof o.body === 'string' ? o.body : JSON.stringify(o.body);
    const r = await fetch(url, init);
    if (!r.ok) return { ok: false, status: r.status, rows: [], total: null };
    const rows = await r.json();
    return { ok: true, status: r.status, rows: Array.isArray(rows) ? rows : [],
             total: o.count ? _totalFrom(r) : null };
  }

  /* كل الصفوف مهما كان عددها — بيلفّ بالـoffset.
     opts: {pageSize, maxRows, method, body, label}                     */
  async function getAll(path, opts) {
    const o = opts || {};
    const size = Math.min(o.pageSize || MAX_ROWS, MAX_ROWS);
    const cap  = o.maxRows || 50000;          // سقف أمان يمنع اللف اللانهائي
    const out = [];
    let total = null, incomplete = false;
    /* بنتقدّم بعدد اللي وصل فعلًا مش بحجم الصفحة اللي طلبناها:
       السيرفر الذاتي ممكن يكون سقفه (PGRST_DB_MAX_ROWS) غير سقف السحابة،
       فلو طلبنا 1000 وهو رجّع 500، التقدّم بـ1000 كان هيتخطّى نص البيانات. */
    let off = 0;
    while (off < cap) {
      const p = await fetchPage(path, { limit: size, offset: off, count: off === 0,
                                        method: o.method, body: o.body });
      if (!p.ok) { incomplete = true; break; }
      if (off === 0) total = p.total;
      for (const row of p.rows) out.push(row);
      if (!p.rows.length) break;                       // مفيش صفوف تانية
      off += p.rows.length;
      if (total != null && out.length >= total) break; // خلّصنا العدد الحقيقي
      if (off >= cap) { incomplete = true; break; }    // سقف الأمان
    }
    try {
      Object.defineProperty(out, 'total', { value: total, enumerable: false });
      Object.defineProperty(out, 'incomplete', { value: incomplete, enumerable: false });
    } catch (e) {}
    if (incomplete) dataWarn((o.label || path.split('?')[0]) + ': البيانات وصلت ناقصة');
    return out;
  }

  /* نفس الفكرة لدالة RPC بترجّع صفوف (setof/table).
     الفلاتر والـlimit/offset بتتطبّق على **ناتج الدالة**، فمش محتاجين
     نعدّل الدالة نفسها (مشتركة بين القاعدتين).                        */
  function rpcAll(fn, body, opts) {
    const o = opts || {};
    const qs = o.query ? ('?' + o.query) : '';
    return getAll('rpc/' + fn + qs, Object.assign({}, o, { method: 'POST', body: body || {} }));
  }

  /* العدد الحقيقي من غير ما نجيب الصفوف */
  async function count(path) {
    const p = await fetchPage(path, { limit: 1, offset: 0, count: true });
    return p.ok ? p.total : null;
  }

  /* ── تحذير مرئي: القص مايعدّيش بصمت ──────────────────────────────
     الرقم الغلط أخطر من الخطأ الواضح — الموظف بياخد قرار على إجمالي
     ناقص وهو مش عارف. فبنطلّع شريط أحمر فوق الشاشة.                 */
  const _warned = new Set();
  function dataWarn(msg) {
    const text = String(msg || '').trim();
    if (!text || _warned.has(text)) return;
    _warned.add(text);
    try { console.error('[بيانات ناقصة] ' + text); } catch (e) {}
    const show = function () {
      try {
        if (!document.body) return;
        let box = document.getElementById('phalix-data-warn');
        if (!box) {
          box = document.createElement('div');
          box.id = 'phalix-data-warn';
          box.setAttribute('dir', 'rtl');
          box.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:99999;background:#b91c1c;' +
            'color:#fff;font-family:Cairo,system-ui,sans-serif;font-size:13px;font-weight:700;' +
            'padding:8px 14px;box-shadow:0 2px 10px rgba(0,0,0,.25);line-height:1.7;';
          box.innerHTML = '<span style="float:left;cursor:pointer;padding:0 6px" ' +
            'onclick="this.parentNode.remove()">✕</span>' +
            '<div id="phalix-data-warn-list"></div>';
          document.body.appendChild(box);
        }
        const list = document.getElementById('phalix-data-warn-list');
        const line = document.createElement('div');
        line.textContent = '⚠️ ' + text + ' — الأرقام المعروضة ممكن تكون ناقصة، بلّغ الدعم';
        list.appendChild(line);
      } catch (e) {}
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', show);
    else show();
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
           refresh, validToken, bearer, headers, client,
           save, resolveBranchId, clear, logout, loginPage, thisPage,
           pages, can, require, tabRules, tabAllowed, guardTabs,
           MAX_ROWS, fetchPage, getAll, rpcAll, count, dataWarn };
})();

/* ═══════════ حارس القص الصامت (بيلفّ fetch مرة واحدة) ═══════════
   الشاشات القديمة بتنادي fetch مباشرة، وبعضها بيجيب «كل الصفوف» من غير
   ترقيم. لو الرد رجع 1000 صف بالظبط والنداء ماطلبش limit، يبقى ده قص
   شبه مؤكّد — فبنطلّع تحذير مرئي بدل ما الشاشة تحسب على بيانات ناقصة.
   بنفحص الردود الكبيرة بس (>20KB) عشان مانحمّلش كل نداء صغير.
   ⚠️ supabase-js بيستعمل window.fetch برضه، فالحارس بيغطي شاشات
      التوصيل كمان من غير أي تعديل فيها.                              */
(function () {
  if (typeof window === 'undefined' || !window.fetch || window.__phalixFetchGuard) return;
  window.__phalixFetchGuard = true;
  const orig = window.fetch.bind(window);
  window.fetch = async function (input, init) {
    const res = await orig(input, init);
    try {
      const url = typeof input === 'string' ? input : (input && input.url) || '';
      if (url.indexOf('/rest/v1/') < 0 || /[?&]limit=/.test(url)) return res;
      if (!res.ok) return res;
      const ct = res.headers.get('content-type') || '';
      if (ct.indexOf('json') < 0) return res;
      res.clone().text().then(function (txt) {
        if (!txt || txt.length < 20000 || txt[0] !== '[') return;
        let rows; try { rows = JSON.parse(txt); } catch (e) { return; }
        if (Array.isArray(rows) && rows.length === Session.MAX_ROWS) {
          const path = url.split('/rest/v1/')[1].split('?')[0];
          Session.dataWarn('«' + path + '» رجّع 1000 صف بالظبط (سقف السيرفر)');
        }
      }).catch(function () {});
    } catch (e) {}
    return res;
  };
})();

