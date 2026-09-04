/* ═══════════════════════════════════════════════════════════════════
   قياس ساعة الجهاز — السبب الأرجح لشاشة فاضية مع كل الحسابات
   ═══════════════════════════════════════════════════════════════════
   لو ساعة الجهاز مقدّمة، أي توكن جديد بيبان **منتهي فور صدوره**،
   فالصفحة ترجع لمفتاح anon وكل حاجة ترجّع 401 — مع أي حساب.

   الاستعمال: على الجهاز اللي فيه المشكلة، افتح phalix.ebrahimhamdy.com
   ← F12 ← Console ← الصق ده ← Enter. انسخ الناتج وابعته.
   ⚠️ مابيطبعش أي سر.
   ═══════════════════════════════════════════════════════════════════ */
(async () => {
  const out = {};
  out['ساعة الجهاز'] = new Date().toString().slice(0, 33);

  // ── 1) قياس الفرق من ترويسة Date بتاعة السيرفر ─────────────────
  let skew = null;
  for (const url of [PHALIX_CONFIG.supabaseUrl + '/auth/v1/health',
                     PHALIX_CONFIG.supabaseUrl + '/rest/v1/',
                     location.origin + '/config.js?t=' + Math.random()]) {
    try {
      const t0 = Date.now();
      const r = await fetch(url, { cache: 'no-store' });
      const t1 = Date.now();
      const d = r.headers.get('date');
      if (d) { skew = Math.round(((t0 + t1) / 2 - new Date(d).getTime()) / 1000); break; }
    } catch (e) { /* نجرّب اللي بعده */ }
  }
  out['فرق الساعة (ثانية)'] = skew;
  out['الحكم'] = skew === null ? '⚠️ مقدرتش أقيس'
    : Math.abs(skew) < 90 ? '✅ الساعة مظبوطة — السبب حاجة تانية'
    : (skew > 0 ? '❌ الجهاز مقدّم ' : '❌ الجهاز مأخّر ')
      + Math.round(Math.abs(skew) / 60) + ' دقيقة — ده السبب';

  // ── 2) الدليل القاطع: نجيب توكن جديد ونشوف بيبان منتهي ولا لأ ──
  //     (بنستعمل الـrefresh token الموجود — مفيش باسورد ولا تسجيل دخول)
  const rt = localStorage.getItem('sbRefresh');
  if (rt) {
    try {
      const r = await fetch(PHALIX_CONFIG.supabaseUrl + '/auth/v1/token?grant_type=refresh_token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: PHALIX_CONFIG.supabaseAnonKey },
        body: JSON.stringify({ refresh_token: rt })
      });
      const d = await r.json();
      if (!r.ok || !d.access_token) {
        out['تجديد التوكن'] = '❌ فشل: ' + (d.error_description || d.msg || d.error || r.status);
      } else {
        const p = JSON.parse(atob(d.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
        const ageSec = Math.round(Date.now() / 1000 - p.iat);      // عمر التوكن حسب الجهاز
        const leftMin = Math.round((p.exp * 1000 - Date.now()) / 60000);
        out['تجديد التوكن'] = '✅ نجح';
        out['عمر التوكن الجديد حسب الجهاز (ثانية)'] = ageSec;
        out['باقي عليه (دقيقة)'] = leftMin;
        out['الدليل'] = Math.abs(ageSec) < 90
          ? '✅ توكن جديد وعمره صفر — الساعة سليمة'
          : '❌ توكن لسه صادر وعمره ' + Math.round(ageSec / 60) + ' دقيقة — **ساعة الجهاز غلط**';
        // نحفظ التوكن الجديد فعلاً عشان الجهاز يشتغل لو الساعة سليمة
        localStorage.setItem('authJwt', d.access_token);
        localStorage.setItem('authToken', d.access_token);
        if (d.refresh_token) localStorage.setItem('sbRefresh', d.refresh_token);
      }
    } catch (e) { out['تجديد التوكن'] = '❌ ' + e.message; }
  } else {
    out['تجديد التوكن'] = '⚠️ مفيش refresh token — سجّل دخول الأول';
  }

  // ── 3) نداء حقيقي بعد التجديد ──────────────────────────────────
  try {
    const r = await fetch(PHALIX_CONFIG.supabaseUrl + '/rest/v1/contract_invoices?select=id&limit=1',
                          { headers: await Session.headers() });
    out['نداء بعد التجديد'] = r.status + (r.status === 200 ? ' ✅ شغّال' : ' ❌');
  } catch (e) { out['نداء بعد التجديد'] = '❌ ' + e.message; }

  console.table(out);
  return out;
})();
