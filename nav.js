function injectNavbar() {
  var currentPage      = window.location.pathname.split("/").pop();
  var userRoleEarly    = localStorage.getItem('userRole') || '';

  // ===== تقييد مسؤول الجرد: لا يرى ولا يصل لأي شاشة غير الجرد =====
  if (userRoleEarly === 'inventory') {
    if (currentPage !== 'inventory.html') {
      window.location.replace('inventory.html');
      return;
    }
    var activeUserInv = localStorage.getItem('activeUser');
    var displayInv    = activeUserInv ? String(activeUserInv).replace(/['"<>]/g, '') : '';
    var navContentInv =
      '<div class="nav-logo">' +
        '<span style="font-weight:900;font-size:1.1rem;letter-spacing:1px;">Phalix</span>' +
      '</div>' +
      '<nav class="nav-links">' +
        '<a href="inventory.html" class="active">' +
          '<i class="fas fa-clipboard-list"></i> جرد</a>' +
      '</nav>' +
      '<div class="user-info">' +
        '<span id="nav-user">' + displayInv + '</span>' +
        '<button class="btn-logout" onclick="logout()">' +
          '<i class="fas fa-sign-out-alt"></i>' +
        '</button>' +
      '</div>';
    var navBarInv = document.querySelector('.nav-bar');
    if (navBarInv) navBarInv.innerHTML = navContentInv;
    return;
  }

  var contractPages    = ['sales_contracts.html', 'claims.html', 'contracts.html', 'contracts_stats.html'];
  var csPages          = ['customer_service.html', 'shortages.html'];
  var purchasesPages   = ['purchases.html', 'cosmo_order.html', 'inventory_management.html'];
  var visaPages        = ['visa_transactions.html', 'bank_monitor.html', 'paymob.html', 'sms.html'];
  var isContractPage   = contractPages.includes(currentPage);
  var isCSPage         = csPages.includes(currentPage);
  var isPurchasesPage  = purchasesPages.includes(currentPage);
  var isVisaPage       = visaPages.includes(currentPage);
  var activeUserVal    = localStorage.getItem('activeUser');
  var displayUser      = activeUserVal ? String(activeUserVal).replace(/['"<>]/g, '') : '';
  var userRole         = localStorage.getItem('userRole') || '';
  var isAdmin          = userRole === 'admin';
  var isManager        = userRole === 'manager';

  var navContent =
    '<div class="nav-logo">' +
      '<span style="font-weight:900;font-size:1.1rem;letter-spacing:1px;">Phalix</span>' +
    '</div>' +
    '<nav class="nav-links">' +
      '<a href="delivery/auth.html" style="color:#38bdf8;font-weight:700;background:rgba(56,189,248,.12);padding:7px 12px;border-radius:8px;font-size:0.8rem;display:flex;align-items:center;gap:5px;text-decoration:none;white-space:nowrap;">' +
        '<i class="fas fa-motorcycle"></i> التوصيل</a>' +

      '<a href="main.html" class="' + (currentPage === 'main.html' ? 'active' : '') + '">' +
        '<i class="fas fa-plus-circle"></i> مدخلات</a>' +

      '<a id="purchases-toggle" href="#" style="' +
        'color:' + (isPurchasesPage ? 'var(--primary)' : '#94a3b8') + ';' +
        'background:' + (isPurchasesPage ? 'var(--accent)' : 'transparent') + ';' +
        'padding:7px 12px;border-radius:8px;font-size:0.8rem;' +
        'font-weight:' + (isPurchasesPage ? '700' : '500') + ';' +
        'display:flex;align-items:center;gap:5px;text-decoration:none;white-space:nowrap;cursor:pointer;">' +
        '<i class="fas fa-warehouse"></i> إدارة المخزون' +
        '<i class="fas fa-chevron-down" style="font-size:0.6rem;margin-right:2px;"></i>' +
      '</a>' +

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

      '<a id="visa-toggle" href="#" style="' +
        'color:' + (isVisaPage ? 'var(--primary)' : '#94a3b8') + ';' +
        'background:' + (isVisaPage ? 'var(--accent)' : 'transparent') + ';' +
        'padding:7px 12px;border-radius:8px;font-size:0.8rem;' +
        'font-weight:' + (isVisaPage ? '700' : '500') + ';' +
        'display:flex;align-items:center;gap:5px;text-decoration:none;white-space:nowrap;cursor:pointer;">' +
        '<i class="fas fa-credit-card"></i> فيزا' +
        '<i class="fas fa-chevron-down" style="font-size:0.6rem;margin-right:2px;"></i>' +
      '</a>' +

      '<a href="missing_items.html" class="' + (currentPage === 'missing_items.html' ? 'active' : '') + '">' +
        '<i class="fas fa-truck"></i> لم يصل من الشركات</a>' +
      '<a href="inventory_min.html" class="' + (currentPage === 'inventory_min.html' ? 'active' : '') + '">' +
        '<i class="fas fa-boxes"></i> حدود المخزون</a>' +
      '<a href="customers.html" class="' + (currentPage === 'customers.html' ? 'active' : '') + '">' +
        '<i class="fas fa-users"></i> العملاء</a>' +
      (isAdmin || isManager ?
        '<a href="employees.html" class="' + (currentPage === 'employees.html' ? 'active' : '') + '">' +
          '<i class="fas fa-user-tie"></i> الموظفين</a>'
        : '') +
      (isAdmin ?
        '<a href="dashboard.html" class="' + (currentPage === 'dashboard.html' ? 'active' : '') + '" style="color:#f59e0b;font-weight:700;">' +
          '<i class="fas fa-chart-line"></i> داشبورد</a>'
        : '') +
    '</nav>' +
    '<div class="user-info">' +
      '<span id="nav-user">' + displayUser + '</span>' +
      '<button class="btn-logout" onclick="logout()">' +
        '<i class="fas fa-sign-out-alt"></i>' +
      '</button>' +
    '</div>';

  var navBar = document.querySelector('.nav-bar');
  if (navBar) navBar.innerHTML = navContent;

  var purchasesItems = [
    { href: 'purchases.html', icon: 'fa-shopping-cart', label: 'مشتريات', active: currentPage === 'purchases.html' }
  ];
  purchasesItems.push(
    { href: 'cosmo_order.html', icon: 'fa-shopping-basket', label: 'طلبيات الكوزمو', active: currentPage === 'cosmo_order.html' }
  );
  purchasesItems.push(
    { href: 'inventory_management.html', icon: 'fa-warehouse', label: 'إدارة المخزون', active: currentPage === 'inventory_management.html' }
  );
  createFloatingDropdown('purchases-dropdown', purchasesItems);

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

  createFloatingDropdown('visa-dropdown', [
    { href: 'visa_transactions.html', icon: 'fa-credit-card',          label: 'معاملات الفيزا',  active: currentPage === 'visa_transactions.html' },
    { href: 'bank_monitor.html',      icon: 'fa-university',           label: 'متابعة البنك',    active: currentPage === 'bank_monitor.html' },
    { href: 'paymob.html',            icon: 'fa-mobile-screen-button', label: 'معاملات باي موب', active: currentPage === 'paymob.html' },
    { href: 'sms.html',               icon: 'fa-wallet',               label: 'معاملات المحافظ', active: currentPage === 'sms.html' }
  ]);

  bindToggle('purchases-toggle', 'purchases-dropdown');
  bindToggle('cs-toggle',        'cs-dropdown');
  bindToggle('contracts-toggle', 'contracts-dropdown');
  bindToggle('visa-toggle',      'visa-dropdown');
}
