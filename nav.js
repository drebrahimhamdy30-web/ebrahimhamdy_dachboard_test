// ===== Navbar =====
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
        <i class="fas fa-bell" style="position:relative;">
        </i>
        <span id="notif-badge" style="
          display:none;
          position:absolute;
          top:-4px;
          right:-8px;
          background:#ef4444;
          color:#fff;
          border-radius:50%;
          width:16px;
          height:16px;
          font-size:0.6rem;
          font-weight:700;
          align-items:center;
          justify-content:center;
          line-height:16px;
          text-align:center;
        ">0</span>
        إشعارات
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

document.addEventListener('DOMContentLoaded', () => {
  injectNavbar();
  setTimeout(startNotifWatcher, 2000);
});

// ===== نظام التنبيهات الذكي =====
let lastNotifCount = -1;
let notifInterval  = null;

function startNotifWatcher() {
  const token = localStorage.getItem('authToken');
  if (!token) return;

  // مش بيتحقق فوراً — بس بيبدأ العداد من الساعة اللي فاتت
  const lastCheck = parseInt(localStorage.getItem('lastNotifCheck') || '0');
  const now       = Date.now();
  const oneHour   = 60 * 60 * 1000;

  // لو فات أكتر من ساعة من آخر تحقق — اتحقق دلوقتي
  if (now - lastCheck >= oneHour) {
    checkNotifications();
  }

  // كل ساعة اتحقق
  notifInterval = setInterval(checkNotifications, oneHour);
}

async function checkNotifications() {
  try {
    const data       = await fetchFromN8N('notifications');
    const items      = Array.isArray(data) ? data : [];
    const userBranch = (localStorage.getItem('userBranch') || '').trim();

    const pending = items.filter(item => {
      const isReceived = String(item.target_branch || '').trim() === userBranch;
      const isDone     = (item.done === "تم" || item.done === true || item.done === "true");
      // احفظ وقت آخر تحقق
localStorage.setItem('lastNotifCheck', Date.now().toString());
      return isReceived && !isDone;
    });

    const count = pending.length;

    updateNotifBadge(count);

    // نبّه بس لو الرقم اتغير وأكبر من صفر
    if (count > 0 && count !== lastNotifCount) {
      showNotifPopup(count);
      playNotifSound();
    }

    lastNotifCount = count;
  } catch(e) {
    console.log('Notif check failed:', e);
  }
}

function updateNotifBadge(count) {
  const badge = document.getElementById('notif-badge');
  if (!badge) return;
  if (count > 0) {
    badge.textContent  = count;
    badge.style.display = 'flex';
  } else {
    badge.style.display = 'none';
  }
}

function showNotifPopup(count) {
  const old = document.getElementById('notif-popup');
  if (old) old.remove();

  const popup = document.createElement('div');
  popup.id = 'notif-popup';
  popup.innerHTML = `
    <style>
      @keyframes slideUp {
        from { opacity:0; transform:translateX(-50%) translateY(20px); }
        to   { opacity:1; transform:translateX(-50%) translateY(0); }
      }
      @keyframes popupOut {
        from { opacity:1; transform:translateX(-50%) translateY(0); }
        to   { opacity:0; transform:translateX(-50%) translateY(20px); }
      }
    </style>
    <div id="notif-popup-inner" style="
      position:fixed;
      bottom:24px;
      left:50%;
      transform:translateX(-50%);
      background:#1e293b;
      border:2px solid #f59e0b;
      border-radius:16px;
      padding:18px 24px;
      box-shadow:0 8px 32px rgba(0,0,0,0.5);
      z-index:99999;
      display:flex;
      align-items:center;
      gap:14px;
      min-width:300px;
      max-width:90vw;
      animation:slideUp 0.3s ease;
      font-family:'Tajawal',sans-serif;
      direction:rtl;
    ">
      <div style="font-size:2rem;animation:none;">🔔</div>
      <div style="flex:1;">
        <div style="font-weight:700;color:#f59e0b;font-size:0.95rem;margin-bottom:4px;">
          لديك ${count} إشعار${count > 1 ? 'ات' : ''} غير مكتمل${count > 1 ? 'ة' : ''}
        </div>
        <div style="font-size:0.82rem;color:#94a3b8;">
          برجاء مراجعة شاشة الإشعارات
        </div>
      </div>
      <div style="display:flex;flex-direction:column;gap:8px;flex-shrink:0;">
        <button onclick="window.location.href='notifications.html'" style="
          padding:8px 14px;
          background:#f59e0b;
          color:#000;
          border:none;
          border-radius:8px;
          font-weight:700;
          cursor:pointer;
          font-family:'Tajawal',sans-serif;
          font-size:0.82rem;
          white-space:nowrap;
        ">عرض الإشعارات</button>
        <button onclick="closeNotifPopup()" style="
          padding:6px 14px;
          background:transparent;
          color:#64748b;
          border:1px solid #334155;
          border-radius:8px;
          cursor:pointer;
          font-family:'Tajawal',sans-serif;
          font-size:0.78rem;
        ">إغلاق</button>
      </div>
    </div>
  `;
  document.body.appendChild(popup);

  // إغلاق تلقائي بعد 8 ثواني
  setTimeout(() => closeNotifPopup(), 8000);
}

function closeNotifPopup() {
  const popup = document.getElementById('notif-popup');
  if (!popup) return;
  popup.remove();
}

function playNotifSound() {
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const notes = [880, 1046, 880];
    notes.forEach((freq, i) => {
      const osc  = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.frequency.value = freq;
      osc.type = 'sine';
      const t = ctx.currentTime + i * 0.18;
      gain.gain.setValueAtTime(0.3, t);
      gain.gain.exponentialRampToValueAtTime(0.001, t + 0.15);
      osc.start(t);
      osc.stop(t + 0.15);
    });
  } catch(e) {
    console.log('Sound failed:', e);
  }
}
