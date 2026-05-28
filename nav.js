function injectNavbar() {
  const currentPage   = window.location.pathname.split("/").pop();
  const contractPages = ['sales_contracts.html', 'claims.html', 'contracts.html'];
  const isContractPage = contractPages.includes(currentPage);

  const navContent = `
<div class="nav-logo">
  <span style="font-weight:900;font-size:1.1rem;letter-spacing:1px;">Phalix</span>
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
  <a href="notifications.html" class="${currentPage === 'notifications.html' ? 'active' : ''}" style="position:relative;">
    <i class="fas fa-bell"></i>
    <span id="notif-badge" style="display:none;position:absolute;top:-4px;right:-8px;background:#ef4444;color:#fff;border-radius:50%;width:16px;height:16px;font-size:0.6rem;font-weight:700;align-items:center;justify-content:center;line-height:16px;text-align:center;">0</span>
    إشعارات
  </a>
  <a href="offers.html" class="${currentPage === 'offers.html' ? 'active' : ''}">
    <i class="fas fa-tags"></i> عروض
  </a>

  <div style="position:relative;display:flex;align-items:center;">
    <a href="#" onclick="toggleContractsDropdown(event)" style="color:${isContractPage ? 'var(--primary)' : '#94a3b8'};background:${isContractPage ? 'var(--accent)' : 'transparent'};padding:7px 12px;border-radius:8px;font-size:0.8rem;font-weight:${isContractPage ? '700' : '500'};display:flex;align-items:center;gap:5px;text-decoration:none;white-space:nowrap;cursor:pointer;">
      <i class="fas fa-file-contract"></i> تعاقدات
      <i class="fas fa-chevron-down" style="font-size:0.6rem;margin-right:2px;"></i>
    </a>
    <div id="contracts-dropdown" style="display:none;position:absolute;top:calc(100% + 6px);right:0;background:#1e293b;border:1px solid #334155;border-radius:10px;min-width:210px;box-shadow:0 8px 24px rgba(0,0,0,0.5);z-index:9999;overflow:hidden;">
      <a href="sales_contracts.html" style="display:flex;align-items:center;gap:8px;padding:11px 16px;text-decoration:none;font-size:0.82rem;color:${currentPage === 'sales_contracts.html' ? '#38bdf8' : '#94a3b8'};background:${currentPage === 'sales_contracts.html' ? '#0c4a6e' : 'transparent'};border-bottom:1px solid #334155;">
        <i class="fas fa-file-invoice"></i> فواتير التعاقد
      </a>
      <a href="claims.html" style="display:flex;align-items:center;gap:8px;padding:11px 16px;text-decoration:none;font-size:0.82rem;color:${currentPage === 'claims.html' ? '#38bdf8' : '#94a3b8'};background:${currentPage === 'claims.html' ? '#0c4a6e' : 'transparent'};border-bottom:1px solid #334155;">
        <i class="fas fa-file-invoice-dollar"></i> مطالبات
      </a>
      <a href="contracts.html" style="display:flex;align-items:center;gap:8px;padding:11px 16px;text-decoration:none;font-size:0.82rem;color:${currentPage === 'contracts.html' ? '#38bdf8' : '#94a3b8'};background:${currentPage === 'contracts.html' ? '#0c4a6e' : 'transparent'};">
        <i class="fas fa-file-contract"></i> لنا فواتير لدى العملاء
      </a>
    </div>
  </div>

  <a href="visa_transactions.html" class="${currentPage === 'visa_transactions.html' ? 'active' : ''}">
    <i class="fas fa-credit-card"></i> فيزا
  </a>
  <a href="missing_items.html" class="${currentPage === 'missing_items.html' ? 'active' : ''}">
    <i class="fas fa-truck"></i> لم يصل من الشركات
  </a>
  <a href="inventory_min.html" class="${currentPage === 'inventory_min.html' ? 'active' : ''}">
    <i class="fas fa-boxes"></i> حدود المخزون
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

function toggleContractsDropdown(e) {
  e.preventDefault();
  e.stopPropagation();
  const menu = document.getElementById('contracts-dropdown');
  if (!menu) return;
  menu.style.display = (menu.style.display === 'none' || menu.style.display === '') ? 'block' : 'none';
}

document.addEventListener('DOMContentLoaded', function() {
  injectNavbar();
  setTimeout(startNotifWatcher, 2000);

  document.addEventListener('click', function() {
    const menu = document.getElementById('contracts-dropdown');
    if (menu) menu.style.display = 'none';
  });
});

// ===== نظام التنبيهات =====
var lastNotifCount = -1;
var notifInterval  = null;

function startNotifWatcher() {
  var token = localStorage.getItem('authToken');
  if (!token) return;

  var lastCheck = parseInt(localStorage.getItem('lastNotifCheck') || '0');
  var now       = Date.now();
  var oneHour   = 60 * 60 * 1000;

  if (now - lastCheck >= oneHour) {
    checkNotifications();
  }

  notifInterval = setInterval(checkNotifications, oneHour);
}

async function checkNotifications() {
  try {
    var data       = await fetchFromN8N('notifications');
    var items      = Array.isArray(data) ? data : [];
    var userBranch = (localStorage.getItem('userBranch') || '').trim();

    var pending = items.filter(function(item) {
      var isReceived = String(item.target_branch || '').trim() === userBranch;
      var isDone     = (item.done === 'تم' || item.done === true || item.done === 'true');
      return isReceived && !isDone;
    });

    localStorage.setItem('lastNotifCheck', Date.now().toString());

    var count = pending.length;
    updateNotifBadge(count);

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
  var badge = document.getElementById('notif-badge');
  if (!badge) return;
  if (count > 0) {
    badge.textContent   = count;
    badge.style.display = 'flex';
  } else {
    badge.style.display = 'none';
  }
}

function showNotifPopup(count) {
  var old = document.getElementById('notif-popup');
  if (old) old.remove();

  var notifLabel = count > 1 ? 'إشعارات غير مكتملة' : 'إشعار غير مكتمل';
  var notifText  = 'لديك ' + count + ' ' + notifLabel;

  var popup = document.createElement('div');
  popup.id = 'notif-popup';

  var inner = document.createElement('div');
  inner.id = 'notif-popup-inner';
  inner.style.cssText = [
    'position:fixed', 'bottom:24px', 'left:50%',
    'transform:translateX(-50%)',
    'background:#1e293b', 'border:2px solid #f59e0b',
    'border-radius:16px', 'padding:18px 24px',
    'box-shadow:0 8px 32px rgba(0,0,0,0.5)',
    'z-index:99999', 'display:flex', 'align-items:center', 'gap:14px',
    'min-width:300px', 'max-width:90vw',
    "font-family:'Tajawal',sans-serif", 'direction:rtl'
  ].join(';');

  inner.innerHTML =
    '<div style="font-size:2rem;">🔔</div>' +
    '<div style="flex:1;">' +
      '<div style="font-weight:700;color:#f59e0b;font-size:0.95rem;margin-bottom:4px;">' + notifText + '</div>' +
      '<div style="font-size:0.82rem;color:#94a3b8;">برجاء مراجعة شاشة الإشعارات</div>' +
    '</div>' +
    '<div style="display:flex;flex-direction:column;gap:8px;flex-shrink:0;">' +
      '<button onclick="window.location.href=\'notifications.html\'" style="padding:8px 14px;background:#f59e0b;color:#000;border:none;border-radius:8px;font-weight:700;cursor:pointer;font-family:\'Tajawal\',sans-serif;font-size:0.82rem;white-space:nowrap;">عرض الإشعارات</button>' +
      '<button onclick="closeNotifPopup()" style="padding:6px 14px;background:transparent;color:#64748b;border:1px solid #334155;border-radius:8px;cursor:pointer;font-family:\'Tajawal\',sans-serif;font-size:0.78rem;">إغلاق</button>' +
    '</div>';

  popup.appendChild(inner);
  document.body.appendChild(popup);
  setTimeout(function() { closeNotifPopup(); }, 8000);
}

function closeNotifPopup() {
  var popup = document.getElementById('notif-popup');
  if (!popup) return;
  popup.remove();
}

function playNotifSound() {
  try {
    var ctx   = new (window.AudioContext || window.webkitAudioContext)();
    var notes = [880, 1046, 880];
    notes.forEach(function(freq, i) {
      var osc  = ctx.createOscillator();
      var gain = ctx.createGain();
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.frequency.value = freq;
      osc.type = 'sine';
      var t = ctx.currentTime + i * 0.18;
      gain.gain.setValueAtTime(1.0, t);
      gain.gain.exponentialRampToValueAtTime(0.001, t + 0.15);
      osc.start(t);
      osc.stop(t + 0.15);
    });
  } catch(e) {
    console.log('Sound failed:', e);
  }
}
