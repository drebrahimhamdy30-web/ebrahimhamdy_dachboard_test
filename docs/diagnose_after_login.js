/* بعد تسجيل الدخول مباشرة (وأول ما البانر يظهر): الصق ده في الكونسول */
(() => {
  const o = {};
  o['ساعة الجهاز'] = new Date().toString().slice(0, 34);

  const t = localStorage.getItem('authJwt');
  o['فيه توكن؟'] = t ? 'أيوة' : '❌ لأ';
  if (t) {
    try {
      const p = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      o['صدر من (ثانية فاتت)'] = Math.round(Date.now() / 1000 - p.iat);
      o['باقي عليه (دقيقة)']   = Math.round((p.exp * 1000 - Date.now()) / 60000);
      o['الدور']               = p.role;
      o['الحكم'] = Math.abs(Date.now() / 1000 - p.iat) < 120
        ? '✅ توكن جديد وعمره صفر — الساعة سليمة'
        : '❌ توكن لسه صادر وعمره ' + Math.round((Date.now() / 1000 - p.iat) / 60) + ' دقيقة — الساعة لسه غلط';
    } catch (e) { o['التوكن'] = '❌ مكسور'; }
  }
  o['مزوّد الدخول'] = localStorage.getItem('authProvider') || '(فاضي)';
  o['فيه refresh؟'] = localStorage.getItem('sbRefresh') ? 'أيوة' : '❌ لأ';
  o['وقت الدخول المخزّن'] = localStorage.getItem('loginTime') || '(فاضي)';

  // رأي session.js نفسه
  try { o['Session.tokenValid()'] = Session.tokenValid() ? '✅ صالح' : '❌ مش صالح'; } catch (e) {}
  try { o['Session.isLoggedIn()'] = Session.isLoggedIn() ? 'أيوة' : 'لأ'; } catch (e) {}

  console.table(o);
  return o;
})();
