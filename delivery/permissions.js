// ===== نظام الجلسة الموحّد (SSO) =====

function getCurrentUser() {
  const token = localStorage.getItem('authToken');
  const activeUser = localStorage.getItem('activeUser');
  if (!token || !activeUser) return null;
  return {
    id: activeUser,
    legacyId: localStorage.getItem('legacyId') || null,
    username: activeUser,
    full_name: localStorage.getItem('fullName') || activeUser,
    role: localStorage.getItem('userRole') || '',
    branch: localStorage.getItem('userBranch') || '',
    branch_id: localStorage.getItem('userBranchId') || null
  };
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
  localStorage.removeItem('authToken');
  localStorage.removeItem('activeUser');
  localStorage.removeItem('userBranch');
  localStorage.removeItem('userBranchId');
  localStorage.removeItem('userRole');
  localStorage.removeItem('fullName');
  localStorage.removeItem('legacyId');
  localStorage.removeItem('loginTime');
  window.location.href = 'auth.html';
}
