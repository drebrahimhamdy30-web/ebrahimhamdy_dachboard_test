function injectNavbar() {
  const currentPage = window.location.pathname.split("/").pop();

  const navContent = `
    <div class="nav-logo">
      <i class="fas fa-clinic-medical"></i> د. إبراهيم
    </div>
    <nav class="nav-links">
      <a href="main.html" class="${currentPage === 'main.html' ? 'active' : ''}">
        <i class="fas fa-plus-circle"></i> مدخلات
      </a>
      <a href="purchases.html" class="${currentPage === 'purchases.html' ? 'active' : ''}">
        <i class="fas fa-shopping-cart"></i> مشتريات
      </a>
      <a href="transfers.html" class="${currentPage === 'transfers.html' ? 'active' : ''}">
        <i class="fas fa-exchange-alt"></i> تحويلات
      </a>
      <a href="customer_service.html" class="${currentPage === 'customer_service.html' ? 'active' : ''}">
        <i class="fas fa-headset"></i> خدمة العملاء
      </a>
      <a href="shortages.html" class="${currentPage === 'shortages.html' ? 'active' : ''}">
        <i class="fas fa-exclamation-triangle"></i> نواقص
      </a>
      <a href="inventory.html" class="${currentPage === 'inventory.html' ? 'active' : ''}">
        <i class="fas fa-clipboard-list"></i> جرد
      </a>
      <a href="notifications.html" class="${currentPage === 'notifications.html' ? 'active' : ''}">
        <i class="fas fa-bell"></i> إشعارات
      </a>
      <a href="contracts.html" class="${currentPage === 'contracts.html' ? 'active' : ''}">
        <i class="fas fa-file-contract"></i> تعاقدات
      </a>
      <a href="missing_items.html" class="${currentPage === 'missing_items.html' ? 'active' : ''}">
        <i class="fas fa-truck"></i> لم يصل
      </a>
    </nav>
    <div class="user-info">
      <span id="nav-user">${localStorage.getItem('activeUser') || ''}</span>
      <button class="btn-logout" onclick="logout()">
        <i class="fas fa-sign-out-alt"></i>
      </button>
    </div>
  `;

  const navBar = document.querySelector('.nav-bar');
  if (navBar) navBar.innerHTML = navContent;
}

document.addEventListener('DOMContentLoaded', injectNavbar);
