// ===== نظام الجلسة الموحّد (SSO) =====
// المنطق نفسه اتنقل لـsession.js في جذر المشروع عشان الـERP والتوصيل
// يشتغلوا بنفس المفاتيح ونفس الخروج. الدوال هنا بقت أغلفة رفيعة عشان
// الصفحات القائمة تفضل شغّالة من غير تعديل.
//
// ⚠️ لازم session.js يتحمّل قبل الملف ده.

function getCurrentUser() {
  return Session.user();
}

function requireAuth(allowedRoles = []) {
  const user = Session.user();
  if (!user) { window.location.href = 'auth.html'; return null; }
  if (allowedRoles.length > 0 && !allowedRoles.map(Session.normRole).includes(user.role)) {
    window.location.href = 'auth.html';
    return null;
  }
  return user;
}

// ⚠️ الإصدار القديم كان بيمسح المفاتيح بالاسم وناسي authJwt و sbRefresh
// و authProvider — يعني بعد «الخروج» الجهاز يفضل شايل refresh token صالح
// وsupabase-config.js يفضل يجدّد بيه. Session.clear() بيمسح القائمة كلها.
function logout() {
  Session.logout('auth.html');
}
