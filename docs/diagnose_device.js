/* ═══════════════════════════════════════════════════════════════════
   تشخيص جهاز: ليه الشاشات فاضية عليه وشغّالة على غيره
   ═══════════════════════════════════════════════════════════════════
   الاستعمال: افتح phalix.ebrahimhamdy.com، اضغط F12 → Console،
   الصق ده كله واضغط Enter. انسخ الناتج وابعته.

   ⚠️ مابيطبعش التوكن نفسه ولا أي سر — أرقام وحالات بس.
   ═══════════════════════════════════════════════════════════════════ */
(async () => {
  const out = {};
  const t = localStorage.getItem('authJwt');

  // ── 1) ساعة الجهاز مقابل ساعة السيرفر ──────────────────────────
  let serverMs = null;
  try {
    const r = await fetch(PHALIX_CONFIG.supabaseUrl + '/rest/v1/', { method: 'HEAD' });
    const d = r.headers.get('date');
    if (d) serverMs = new Date(d).getTime();
  } catch (e) {}
  const skew = serverMs ? Math.round((Date.now() - serverMs) / 1000) : null;
  out['فرق ساعة الجهاز عن السيرفر (ثانية)'] = skew;
  out['الساعة مظبوطة؟'] = skew === null ? 'مش متأكد'
    : (Math.abs(skew) < 120 ? '✅ مظبوطة' : '❌ فرق ' + Math.round(Math.abs(skew) / 60) + ' دقيقة — ده السبب');

  // ── 2) حالة التوكن ─────────────────────────────────────────────
  out['فيه توكن؟'] = t ? 'أيوة' : '❌ لأ';
  if (t) {
    try {
      const p = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      const leftSec = Math.round((p.exp * 1000 - Date.now()) / 1000);
      out['الدور في التوكن'] = p.role;
      out['باقي على انتهائه (دقيقة)'] = Math.round(leftSec / 60);
      out['التوكن صالح من وجهة نظر الجهاز؟'] = leftSec > 60 ? '✅ أيوة' : '❌ لأ (منتهي أو الساعة غلط)';
    } catch (e) { out['التوكن'] = '❌ شكله مكسور'; }
  }
  out['فيه refresh token؟'] = localStorage.getItem('sbRefresh') ? 'أيوة' : '❌ لأ';
  out['مزوّد الدخول'] = localStorage.getItem('authProvider') || '(فاضي)';

  // ── 3) هوية المستخدم المخزّنة على الجهاز ───────────────────────
  out['المستخدم'] = localStorage.getItem('activeUser') || '(فاضي)';
  out['الدور'] = localStorage.getItem('userRole') || '(فاضي)';
  out['الفرع'] = localStorage.getItem('userBranch') || '(فاضي)';

  // ── 4) الترويسة اللي الصفحة فعلاً بتبعتها ─────────────────────
  try {
    const h = await Session.headers();
    const a = h.Authorization || '';
    const pl = JSON.parse(atob(a.replace(/^Bearer /, '').split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    out['الصفحة بتبعت'] = pl.sub ? '✅ توكن المستخدم' : ('❌ مفتاح anon — role=' + pl.role);
  } catch (e) { out['الصفحة بتبعت'] = 'مش متأكد: ' + e.message; }

  // ── 5) نداء حقيقي على جدول مقفول ──────────────────────────────
  try {
    const r = await fetch(PHALIX_CONFIG.supabaseUrl + '/rest/v1/contract_invoices?select=id&limit=1',
                          { headers: await Session.headers() });
    out['نداء contract_invoices'] = r.status + (r.status === 200 ? ' ✅' : ' ❌');
  } catch (e) { out['نداء contract_invoices'] = 'فشل: ' + e.message; }

  console.table(out);
  return out;
})();
