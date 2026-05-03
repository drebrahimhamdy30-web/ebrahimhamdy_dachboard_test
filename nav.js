function injectNavbar() {
    const currentPage = window.location.pathname.split("/").pop().toLowerCase() || 'main.html';
    
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
                <li class="${currentPage === 'add_order.html' ? 'active' : ''}">
                    <a href="add_order.html"><i class="fas fa-plus-circle"></i> <span>إضافة طلب جديد</span></a>
                </li>
                <li class="${currentPage === 'shortages.html' ? 'active' : ''}">
                    <a href="shortages.html"><i class="fas fa-exclamation-triangle"></i> <span>النواقص</span></a>
                </li>
                <li>
                    <a href="#" onclick="logout()"><i class="fas fa-sign-out-alt"></i> <span>خروج</span></a>
                </li>
            </ul>
        </nav>`;

    const settingsHTML = `
        <div id="user-settings" class="settings-panel">
            <div class="settings-toggle" onclick="document.getElementById('user-settings').classList.toggle('open')">
                <i class="fas fa-cog"></i>
            </div>
            <h4>إعدادات المظهر</h4>
            <label>حجم العناوين</label>
            <input type="range" min="1.2" max="2.2" step="0.1" value="1.8" oninput="updateTheme('header-size', this.value + 'rem')">
            <label>حجم الخط</label>
            <input type="range" min="0.8" max="1.2" step="0.05" value="1" oninput="updateTheme('body-font-size', this.value + 'rem')">
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
    localStorage.clear();
    window.location.href = 'index.html';
}
