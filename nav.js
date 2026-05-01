function injectNavbar() {
    const currentPage = window.location.pathname.split("/").pop();
    const navContent = `
        <div class="nav-links">
            <a href="main.html" class="${currentPage === 'main.html' ? 'active' : ''}"><i class="fas fa-plus"></i> مدخلات</a>
            <a href="purchases.html" class="${currentPage === 'purchases.html' ? 'active' : ''}"><i class="fas fa-shopping-cart"></i> مشتريات</a>
            <a href="transfers.html" class="${currentPage === 'transfers.html' ? 'active' : ''}"><i class="fas fa-exchange-alt"></i> تحويلات</a>
            <a href="customer_service.html" class="${currentPage === 'customer_service.html' ? 'active' : ''}"><i class="fas fa-headset"></i> خدمة العملاء</a>
            
            <a href="shortages.html" class="${currentPage === 'shortages.html' ? 'active' : ''}">
                <i class="fas fa-exclamation-triangle"></i> النواقص
            </a>

            <a href="inventory.html" class="${currentPage === 'inventory.html' ? 'active' : ''}"><i class="fas fa-list"></i> جرد</a> 
            <a href="notifications.html" class="${currentPage === 'notifications.html' ? 'active' : ''}"><i class="fas fa-bell"></i> إشعارات</a> 
        </div>
        <div class="user-info" style="color: white; font-size: 0.8rem;">
            <span id="nav-user">${localStorage.getItem('activeUser') || ''}</span>
            <button onclick="logout()" style="background:transparent; border:1px solid #fff; color:white; border-radius:4px; cursor:pointer; margin-right:10px; padding: 2px 8px;">خروج</button>
        </div>`;

    const navBarElement = document.querySelector('.nav-bar');
    if (navBarElement) {
        navBarElement.innerHTML = navContent;
    }
}

// تشغيل الدالة فور تحميل الصفحة
document.addEventListener('DOMContentLoaded', injectNavbar);
