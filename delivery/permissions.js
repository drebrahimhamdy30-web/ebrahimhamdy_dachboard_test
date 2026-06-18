// ===== صلاحيات الأدوار =====
// القيم الافتراضية (fallback لو القاعدة مش متاحة)
let PERMISSIONS = {
  admin: {
    canViewOrders: true,
    canCreateOrders: true,
    canEditOrders: true,
    canDeleteOrders: true,
    canAssignDrivers: true,
    canManageTrips: true,
    canViewReports: true,
    canManageUsers: true,
    canViewPermissions: true,
    canViewAllBranches: true,
  },
  supervisor: {
    canViewOrders: true,
    canCreateOrders: true,
    canEditOrders: true,
    canDeleteOrders: false,
    canAssignDrivers: true,
    canManageTrips: true,
    canViewReports: true,
    canManageUsers: false,
    canViewPermissions: false,
    canViewAllBranches: true,
  },
  cashier: {
    canViewOrders: true,
    canCreateOrders: false,
    canEditOrders: false,
    canDeleteOrders: false,
    canAssignDrivers: false,
    canManageTrips: false,
    canViewReports: true,
    canManageUsers: false,
    canViewPermissions: false,
    canViewAllBranches: false,
  },
  pharmacist: {
    canViewOrders: true,
    canCreateOrders: false,
    canEditOrders: false,
    canDeleteOrders: false,
    canAssignDrivers: false,
    canManageTrips: false,
    canViewReports: false,
    canManageUsers: false,
    canViewPermissions: false,
    canViewAllBranches: false,
  },
  driver: {
    canViewOrders: true,
    canCreateOrders: false,
    canEditOrders: false,
    canDeleteOrders: false,
    canAssignDrivers: false,
    canManageTrips: false,
    canViewReports: false,
    canManageUsers: false,
    canViewPermissions: false,
    canViewAllBranches: false,
    onlyOwnTrips: true,
  },
};

// حمّل الصلاحيات الفعلية من القاعدة (تحدّث PERMISSIONS لو فيه تعديلات محفوظة من الشاشة)
async function loadPermissionsFromDB() {
  try {
    if (typeof supabase === 'undefined') return; // مكتبة supabase مش محمّلة في الصفحة دي
    const _url = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
    const _key = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';
    const _db = supabase.createClient(_url, _key);
    const { data } = await _db.from('role_permissions').select('role,permissions');
    if (data && data.length) {
      const fresh = {};
      data.forEach(r => { fresh[r.role] = r.permissions || {}; });
      // ادمج: استبدل القيم بالجاية من القاعدة، مع الإبقاء على الافتراضي لأي مفتاح مش موجود
      Object.keys(fresh).forEach(role => {
        PERMISSIONS[role] = { ...(PERMISSIONS[role] || {}), ...fresh[role] };
      });
    }
  } catch (e) {
    console.warn('loadPermissionsFromDB failed, using defaults', e);
  }
}

function hasPermission(role, permission) {
  return PERMISSIONS[role]?.[permission] === true;
}

function getCurrentUser() {
  const u = sessionStorage.getItem('delivery_user');
  return u ? JSON.parse(u) : null;
}

function requireAuth(allowedRoles = []) {
  const user = getCurrentUser();
  if (!user) {
    window.location.href = 'auth.html';
    return null;
  }
  if (allowedRoles.length > 0 && !allowedRoles.includes(user.role)) {
    window.location.href = 'auth.html';
    return null;
  }
  return user;
}

function logout() {
  sessionStorage.removeItem('delivery_user');
  window.location.href = 'auth.html';
}
