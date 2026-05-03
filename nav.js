function injectNavbar() {
    const currentPage = window.location.pathname.split("/").pop().toLowerCase() || 'main.html';
    
    // 1. محتوى القائمة الجانبية
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
        </ul>
        <div class="sidebar-footer" style="padding: 20px; border-top: 1px solid rgba(255,255,255,0.1); margin-top: auto;">
            <div style="font-size: 0.8rem; margin-bottom: 10px; color: #bdc3c7;">
                <i class="fas fa-user-circle"></i> <span>${localStorage.getItem('userBranch') || 'د. إبراهيم'}</span>
            </div>
            <button onclick="logout()" style="width: 100%; background: #e74c3c; color: white; border: none; padding: 8px; border-radius: 6px; cursor: pointer;">خروج</button>
        </div>`;

    // 2. محتوى لوحة الإعدادات الذكية
    const settingsHTML = `
        <div id="user-settings" class="settings-panel">
            <div class="settings-toggle" onclick="document.getElementById('user-settings').classList.toggle('open')">
                <i class="fas fa-cog"></i>
            </div>
            <h4>إعدادات المظهر</h4>
            <label>حجم العنوان</label>
            <input type="range" min="1.2" max="2.2" step="0.1" value="1.8" oninput="updateTheme('header-size', this.value + 'rem')">
            <label>خط الصفحة</label>
            <input type="range" min="0.8" max="1.2" step="0.05" value="1" oninput="updateTheme('body-font-size', this.value + 'rem')">
            <label>المساحات (Padding)</label>
            <input type="range" min="10" max="50" step="5" value="30" oninput="updateTheme('content-padding', this.value + 'px')">
        </div>`;

    // تنفيذ الحقن
    const sideBarElement = document.querySelector('.sidebar');
    if (sideBarElement) sideBarElement.innerHTML = navContent;
    document.body.insertAdjacentHTML('beforeend', settingsHTML);
    
    // تحميل المظهر المحفوظ
    loadSavedTheme();
}

function updateTheme(property, value) {
    document.documentElement.style.setProperty(`--${property}`, value);
    localStorage.setItem(`theme-${property}`, value);
}

function loadSavedTheme() {
    ['header-size', 'body-font-size', 'content-padding'].forEach(prop => {
        const saved = localStorage.getItem(`theme-${prop}`);
        if (saved) document.documentElement.style.setProperty(`--${prop}`, saved);
    });
}

document.addEventListener('DOMContentLoaded', injectNavbar);
