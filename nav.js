function injectNavbar() {
    // تحديد الصفحة الحالية لتمييزها في القائمة
    const currentPage = window.location.pathname.split("/").pop().toLowerCase() || 'main.html';
    
    // جلب بيانات المستخدم (اختياري - لتحسين التجربة)
    const userName = localStorage.getItem('userName') || 'د. إبراهيم';

    const navContent = `
        <nav class="sidebar">
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
                <li class="${currentPage === 'add_order.html' ? 'active' : ''}">
                    <a href="add_order.html"><i class="fas fa-plus-circle"></i> <span>إضافة طلب جديد</span></a>
                </li>
                <li class="${currentPage === 'inventory.html' ? 'active' : ''}">
                    <a href="inventory.html"><i class="fas fa-boxes"></i> <span>الجرد</span></a>
                </li>
                <li class="${currentPage === 'transfers.html' ? 'active' : ''}">
                    <a href="transfers.html"><i class="fas fa-exchange-alt"></i> <span>التحويلات</span></a>
                </li>
                <li class="${currentPage === 'purchases.html' ? 'active' : ''}">
                    <a href="purchases.html"><i class="fas fa-shopping-cart"></i> <span>المشتريات</span></a>
                </li>
                <li class="${currentPage === 'customer_service.html' ? 'active' : ''}">
                    <a href="customer_service.html"><i class="fas fa-headset"></i> <span>خدمة العملاء</span></a>
                </li>
                <li class="${currentPage === 'notifications.html' ? 'active' : ''}">
                    <a href="notifications.html"><i class="fas fa-bell"></i> <span>الإشعارات</span></a>
                </li>
                <li style="margin-top: 20px; border-top: 1px solid rgba(255,255,255,0.1)">
                    <a href="#" onclick="logout()" style="color: #e74c3c;"><i class="fas fa-sign-out-alt"></i> <span>خروج</span></a>
                </li>
            </ul>
        </nav>`;

    const settingsHTML = `
        <div id="user-settings" class="settings-panel">
            <div class="settings-toggle" onclick="document.getElementById('user-settings').classList.toggle('open')">
                <i class="fas fa-cog"></i>
            </div>
            <h4>إعدادات المظهر</h4>
            <div style="margin-bottom:15px;">
                <label style="display:block; font-size:0.8rem; margin-bottom:5px;">حجم العناوين</label>
                <input type="range" min="1.2" max="2.2" step="0.1" value="1.8" style="width:100%" oninput="updateTheme('header-size', this.value + 'rem')">
            </div>
            <div>
                <label style="display:block; font-size:0.8rem; margin-bottom:5px;">حجم الخط</label>
                <input type="range" min="0.8" max="1.2" step="0.05" value="1" style="width:100%" oninput="updateTheme('body-font-size', this.value + 'rem')">
            </div>
        </div>`;

    const placeholder = document.querySelector('.nav-bar');
    if (placeholder) placeholder.innerHTML = navContent;
    document.body.insertAdjacentHTML('beforeend', settingsHTML);
    loadSavedTheme();
}

function updateTheme(prop, val) {
    document.documentElement.style.setProperty(`--${prop}`, val);
    localStorage.setItem(`theme-${prop}`, val);
}

function loadSavedTheme() {
    ['header-size', 'body-font-size'].forEach(p => {
        const v = localStorage.getItem(`theme-${p}`);
        if (v) document.documentElement.style.setProperty(`--${p}`, v);
    });
}

document.addEventListener('DOMContentLoaded', injectNavbar);

function logout() {
    if(confirm('هل أنت متأكد من تسجيل الخروج؟')) {
        localStorage.clear();
        window.location.href = 'index.html';
    }
}
