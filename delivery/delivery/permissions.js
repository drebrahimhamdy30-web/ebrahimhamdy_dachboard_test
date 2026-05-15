const PERMISSIONS = {
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
