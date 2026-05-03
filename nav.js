function injectNavbar() {
    const currentPage = window.location.pathname.split("/").pop().toLowerCase() || 'main.html';
    
    const navContent = `
        <div class="logo">
            <i class="fas fa-pills"></i>
            <span>إدارة الصيدلية</span>
        </div>
        <ul>
            <li class="${currentPage === 'main.html' ? 'active' : ''}">
                <a href="main.html"><i class="fas fa-chart-line"></i> <span>الإحصائيات</span></a>
            </li>
            <li class="${currentPage === 'shortages.html' ? 'active' : ''}">
                <a href="shortages.html"><i class="fas fa-exclamation-triangle"></i> <span>النواقص</span></a>
            </li>
            <li class="${currentPage === 'purchases.html' ? 'active' : ''}">
                <a href="purchases.html"><i class="fas fa-shopping-cart"></i> <span>المشتريات</span></a>
            </li>
            <li class="${currentPage === 'transfers.html' ? 'active' : ''}">
                <a href="transfers.html"><i class="fas fa-exchange-alt"></i> <span>التحويلات</span></a>
            </li>
            <li class="${currentPage === 'customer_service.html' ? 'active' : ''}">
                <a href="customer_service.html"><i class="fas fa-headset"></i> <span>خدمة العملاء</span></a>
            </li>
            <li class="${currentPage === 'inventory.html' ? 'active' : ''}">
                <a href="inventory.html"><i class="fas fa-list"></i> <span>الجرد الفني</span></a>
            </li>
            <li class="${currentPage === 'notifications.html' ? 'active' : ''}">
                <a href="notifications.html"><i class="fas fa-bell"></i> <span>الإشعارات</span></a>
            </li>
        </ul>
        <div class="sidebar-footer" style="padding: 20px; border-top: 1px solid rgba(255,255,255,0.1); margin-top: auto;">
            <div style="font-size: 0.8rem; margin-bottom: 10px; color: #bdc3c7;">
                <i class="fas fa-user-circle"></i> <span id="nav-user">${localStorage.getItem('activeUser') || 'د. إبراهيم'}</span>
            </div>
            <button onclick="logout()" style="width: 100%; background: #e74c3c; color: white; border: none; padding: 8px; border-radius: 6px; cursor: pointer; font-size: 0.8rem;">
                <i class="fas fa-sign-out-alt"></i> خروج
            </button>
        </div>`;

    // البحث عن عنصر السايدبار وحقن المحتوى فيه
    const sideBarElement = document.querySelector('.sidebar');
    if (sideBarElement) {
        sideBarElement.innerHTML = navContent;
    }
}

// تشغيل الدالة فور تحميل الصفحة
document.addEventListener('DOMContentLoaded', injectNavbar);
