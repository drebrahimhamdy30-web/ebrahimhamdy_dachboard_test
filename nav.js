function injectNavbar() {
  var currentPage    = window.location.pathname.split("/").pop();
  var contractPages  = ['sales_contracts.html', 'claims.html', 'contracts.html', 'contracts_stats.html'];
  var csPages        = ['customer_service.html', 'shortages.html'];
  var isContractPage = contractPages.includes(currentPage);
  var isCSPage       = csPages.includes(currentPage);
  var activeUserVal  = localStorage.getItem('activeUser');
  var displayUser    = activeUserVal ? String(activeUserVal).replace(/['"<>]/g, '') : '';

  var navContent =
    '<div class="nav-logo">' +
      '<span style="font-weight:900;font-size:1.1rem;letter-spacing:1px;">Phalix</span>' +
    '</div>' +
    '<nav class="nav-links">' +
      '<a href="main.html" class="' + (currentPage === 'main.html' ? 'active' : '') + '">' +
        '<i class="fas fa-plus-circle"></i> مدخلات</a>' +
      '<a href="purchases.html" class="' + (currentPage === 'purchases.html' ? 'active' : '') + '">' +
        '<i class="fas fa-shopping-cart"></i> مشتريات</a>' +
      '<a href="transfers.html" class="' + (currentPage === 'transfers.html' ? 'active' : '') + '">' +
        '<i class="fas fa-exchange-alt"></i> تحويلات</a>' +
      '<a id="cs-toggle" href="#" style="' +
        'color:' + (isCSPage ? 'var(--primary)' : '#94a3b8') + ';' +
        'background:' + (isCSPage ? 'var(--accent)' : 'transparent') + ';' +
        'padding:7px 12px;border-radius:8px;font-size:0.8rem;' +
        'font-weight:' + (isCSPage ? '700' : '500') + ';' +
        'display:flex;align-items:center;gap:5px;text-decoration:none;white-space:nowrap;cursor:pointer;">' +
        '<i class="fas fa-headset"></i> خدمة العملاء' +
        '<i class="fas fa-chevron-down" style="font-size:0.6rem;margin-right:2px;"></i>' +
      '</a>' +
      '<a href="inventory.html" class="' + (currentPage === 'inventory.html' ? 'active' : '') + '">' +
        '<i class="fas fa-clipboard-list"></i> جرد</a>' +
      '<a href="notifications.html" class="' + (currentPage === 'notifications.html' ? 'active' : '') + '" style="position:relative;">' +
        '<i class="fas fa-bell"></i>' +
        '<span id="notif-badge" style="display:none;position:absolute;top:-4px;right:-8px;' +
          'background:#ef4444;color:#fff;border-radius:50%;width:16px;height:16px;' +
          'font-size:0.6rem;font-weight:700;align-items:center;justify-content:center;' +
          'line-height:16px;text-align:center;">0</span>' +
        ' إشعارات</a>' +
      '<a href="offers.html" class="' + (currentPage === 'offers.html' ? 'active' : '') + '">' +
        '<i class="fas fa-tags"></i> عروض</a>' +
      '<a id="contracts-toggle" href="#" style="' +
        'color:' + (isContractPage ? 'var(--primary)' : '#94a3b8') + ';' +
        'background:' + (isContractPage ? 'var(--accent)' : 'transparent') + ';' +
        'padding:7px 12px;border-radius:8px;font-size:0.8rem;' +
        'font-weight:' + (isContractPage ? '700' : '500') + ';' +
        'display:flex;align-items:center;gap:5px;text-decoration:none;white-space:nowrap;cursor:pointer;">' +
        '<i class="fas fa-file-contract"></i> تعاقدات' +
        '<i class="fas fa-chevron-down" style="font-size:0.6rem;margin-right:2px;"></i>' +
      '</a>' +
      '<a href="visa_transactions.html" class="' + (currentPage === 'visa_transactions.html' ? 'active' : '') + '">' +
        '<i class="fas fa-credit-card"></i> فيزا</a>' +
      '<a href="missing_items.html" class="' + (currentPage === 'missing_items.html' ? 'active' : '') + '">' +
        '<i class="fas fa-truck"></i> لم يصل من الشركات</a>' +
      '<a href="inventory_min.html" class="' + (currentPage === 'inventory_min.html' ? 'active' : '') + '">' +
        '<i class="fas fa-boxes"></i> حدود المخزون</a>' +
    '</nav>' +
    '<div class="user-info">' +
      '<span id="nav-user">' + displayUser + '</span>' +
      '<button class="btn-logout" onclick="logout()">' +
        '<i class="fas fa-sign-out-alt"></i>' +
      '</button>' +
    '</div>';

  var navBar = document.querySelector('.nav-bar');
  if (navBar) navBar.innerHTML = navContent;

  createFloatingDropdown('cs-dropdown', [
    { href: 'customer_service.html', icon: 'fa-headset',             label: 'خدمة العملاء', active: currentPage === 'customer_service.html' },
    { href: 'shortages.html',        icon: 'fa-exclamation-triangle', label: 'نواقص',        active: currentPage === 'shortages.html' }
  ]);

  createFloatingDropdown('contracts-dropdown', [
    { href: 'sales_contracts.html', icon: 'fa-file-invoice',        label: 'فواتير التعاقد',         active: currentPage === 'sales_contracts.html' },
    { href: 'claims.html',          icon: 'fa-file-invoice-dollar', label: 'مطالبات',                active: currentPage === 'claims.html' },
    { href: 'contracts.html',       icon: 'fa-file-contract',       label: 'لنا فواتير لدى العملاء', active: currentPage === 'contracts.html' },
    { href: 'contracts_stats.html', icon: 'fa-chart-bar',           label: 'إحصائيات',               active: currentPage === 'contracts_stats.html' }
  ]);

  bindToggle('cs-toggle',        'cs-dropdown');
  bindToggle('contracts-toggle', 'contracts-dropdown');
}

function createFloatingDropdown(id, items) {
  var old = document.getElementById(id);
  if (old) old.remove();

  var menu = document.createElement('div');
  menu.id = id;
  menu.style.cssText =
    'display:none;position:fixed;' +
    'background:#1e293b;border:1px solid #334155;border-radius:10px;' +
    'min-width:210px;box-shadow:0 8px 24px rgba(0,0,0,0.5);' +
    'z-index:99999;overflow:hidden;';

  items.forEach(function(item, i) {
    var a = document.createElement('a');
    a.href = item.href;
    a.style.cssText =
      'display:flex;align-items:center;gap:8px;padding:11px 16px;' +
      'text-decoration:none;font-size:0.82rem;font-family:Tajawal,sans-serif;' +
      'color:' + (item.active ? '#38bdf8' : '#94a3b8') + ';' +
      'background:' + (item.active ? '#0c4a6e' : 'transparent') + ';' +
      (i < items.length - 1 ? 'border-bottom:1px solid #334155;' : '');
    a.innerHTML = '<i class="fas ' + item.icon + '"></i> ' + item.label;
    menu.appendChild(a);
  });

  document.body.appendChild(menu);
}

function bindToggle(toggleId, menuId) {
  var btn  = document.getElementById(toggleId);
  var menu = document.getElementById(menuId);
  if (!btn || !menu) return;

  btn.addEventListener('click', function(e) {
    e.preventDefault();
    e.stopPropagation();
    ['cs-dropdown', 'contracts-dropdown'].forEach(function(id) {
      if (id !== menuId) {
        var el = document.getElementById(id);
        if (el) el.style.display = 'none';
      }
    });
    if (menu.style.display === 'block') {
      menu.style.display = 'none';
      return;
    }
    var rect = btn.getBoundingClientRect();
    menu.style.top   = (rect.bottom + 6) + 'px';
    menu.style.right = (window.innerWidth - rect.right) + 'px';
    menu.style.left  = 'auto';
    menu.style.display = 'block';
  });
}

// ===== التهيئة — بيشتغل فور تحميل الملف =====
// injectNavbar بيشتغل مباشرة بدون انتظار أي event
// عشان يكون متاح لما الصفحة تستدعيه
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', function() {
    injectNavbar();
    setTimeout(startNotifWatcher, 2000);
    document.addEventListener('click', function() {
      ['cs-dropdown', 'contracts-dropdown'].forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.style.display = 'none';
      });
    });
  });
} else {
  // الـ DOM جاهز بالفعل
  injectNavbar();
  setTimeout(startNotifWatcher, 2000);
  document.addEventListener('click', function() {
    ['cs-dropdown', 'contracts-dropdown'].forEach(function(id) {
      var el = document.getElementById(id);
      if (el) el.style.display = 'none';
    });
  });
}

// ===== نظام التنبيهات =====
var lastNotifCount = -1;
var notifInterval  = null;

function startNotifWatcher() {
  var token = localStorage.getItem('authToken');
  if (!token) return;
  var lastCheck = parseInt(localStorage.getItem('lastNotifCheck') || '0');
  var now       = Date.now();
  var oneHour   = 60 * 60 * 1000;
  if (now - lastCheck >= oneHour) checkNotifications();
  notifInterval = setInterval(checkNotifications, oneHour);
}

async function checkNotifications() {
  try {
    var data       = await fetchFromN8N('notifications');
    var items      = Array.isArray(data) ? data : [];
    var userBranch = (localStorage.getItem('userBranch') || '').trim();
    var pending    = items.filter(function(item) {
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
  badge.textContent   = count;
  badge.style.display = count > 0 ? 'flex' : 'none';
}

function showNotifPopup(count) {
  var old = document.getElementById('notif-popup');
  if (old) old.remove();
  var label = count > 1 ? 'إشعارات غير مكتملة' : 'إشعار غير مكتمل';
  var text  = 'لديك ' + count + ' ' + label;
  var popup = document.createElement('div');
  popup.id  = 'notif-popup';
  var inner = document.createElement('div');
  inner.style.cssText =
    'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);' +
    'background:#1e293b;border:2px solid #f59e0b;border-radius:16px;' +
    'padding:18px 24px;box-shadow:0 8px 32px rgba(0,0,0,0.5);' +
    'z-index:99999;display:flex;align-items:center;gap:14px;' +
    'min-width:300px;max-width:90vw;font-family:Tajawal,sans-serif;direction:rtl;';
  inner.innerHTML =
    '<div style="font-size:2rem;">🔔</div>' +
    '<div style="flex:1;">' +
      '<div style="font-weight:700;color:#f59e0b;font-size:0.95rem;margin-bottom:4px;">' + text + '</div>' +
      '<div style="font-size:0.82rem;color:#94a3b8;">برجاء مراجعة شاشة الإشعارات</div>' +
    '</div>' +
    '<div style="display:flex;flex-direction:column;gap:8px;flex-shrink:0;">' +
      '<button onclick="window.location.href=\'notifications.html\'" ' +
        'style="padding:8px 14px;background:#f59e0b;color:#000;border:none;border-radius:8px;' +
        'font-weight:700;cursor:pointer;font-family:Tajawal,sans-serif;font-size:0.82rem;white-space:nowrap;">' +
        'عرض الإشعارات</button>' +
      '<button onclick="closeNotifPopup()" ' +
        'style="padding:6px 14px;background:transparent;color:#64748b;border:1px solid #334155;' +
        'border-radius:8px;cursor:pointer;font-family:Tajawal,sans-serif;font-size:0.78rem;">' +
        'إغلاق</button>' +
    '</div>';
  popup.appendChild(inner);
  document.body.appendChild(popup);
  setTimeout(closeNotifPopup, 8000);
}

function closeNotifPopup() {
  var popup = document.getElementById('notif-popup');
  if (popup) popup.remove();
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
