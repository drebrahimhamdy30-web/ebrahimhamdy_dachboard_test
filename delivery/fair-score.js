/* ============================================================
   تقييم الطيارين العادل — نصيب مفترض مقابل تسليم فعلي
   يعتمد على: orders.delivered_at + driver_attendance (جلسات online)
   ============================================================ */

const FS_MIN_ORDERS = 5; // حد أدنى لعرض الطيار في الترتيب

/**
 * يجيب الطلبات المسلّمة + جلسات الحضور لفترة، ويحسب التقييم.
 * @param {string} from  تاريخ البداية YYYY-MM-DD
 * @param {string} to    تاريخ النهاية YYYY-MM-DD
 * @param {string} branchId  اختياري: فلترة بفرع
 */
async function computeFairScores(from, to, branchId) {
  // 1) الطلبات المسلّمة فعلاً في الفترة (نفلتر على delivered_at مش created_at)
  let oq = db.from('orders')
    .select('id,driver_id,deliveryman,delivered_at,total_bill_net,status')
    .in('status', ['delivered', 'completed'])
    .not('delivered_at', 'is', null)
    .gte('delivered_at', from + 'T00:00:00')
    .lte('delivered_at', to + 'T23:59:59');
  if (branchId) oq = oq.eq('branch_id', branchId);

  // 2) جلسات الحضور المعتمدة في نفس الفترة
  const aq = db.from('driver_attendance')
    .select('driver_id,status,approved_at,ended_at,date')
    .eq('status', 'online')
    .not('approved_at', 'is', null)
    .gte('date', from).lte('date', to);

  const [oRes, aRes] = await Promise.all([oq, aq]);
  if (oRes.error || aRes.error) {
    console.error(oRes.error || aRes.error);
    return null;
  }

  const orders = oRes.data || [];
  // حوّل الجلسات لفترات زمنية [start, end] — الجلسة المفتوحة تُختم بـ "الآن"
  const sessions = (aRes.data || []).map(r => ({
    driver_id: r.driver_id,
    start: new Date(r.approved_at).getTime(),
    end: r.ended_at ? new Date(r.ended_at).getTime() : Date.now(),
    open: !r.ended_at
  })).filter(s => s.end > s.start);

  // 3) لكل طلب: مين كان أونلاين لحظة التسليم؟
  const stats = {};   // driver_id -> { expected, actual, revenue }
  const ensure = id => (stats[id] = stats[id] || { expected: 0, actual: 0, revenue: 0 });

  let orphanOrders = 0;      // طلبات اتوصلت ومفيش حد أونلاين وقتها
  let unmatchedDriver = 0;   // طلبات من غير driver_id

  orders.forEach(o => {
    const t = new Date(o.delivered_at).getTime();
    const online = sessions.filter(s => t >= s.start && t < s.end);

    if (online.length === 0) {
      orphanOrders++;
    } else {
      const share = 1 / online.length;
      online.forEach(s => { ensure(s.driver_id).expected += share; });
    }

    if (o.driver_id) {
      const d = ensure(o.driver_id);
      d.actual += 1;
      d.revenue += Number(o.total_bill_net || 0);
    } else {
      unmatchedDriver++;
    }
  });

  // 4) احسب الكفاءة
  const rows = Object.entries(stats).map(([driver_id, s]) => ({
    driver_id,
    expected: s.expected,
    actual: s.actual,
    revenue: s.revenue,
    // الكفاءة = فعلي ÷ مفترض. لو المفترض صفر (وصّل بدون جلسة حضور) نسيبها null
    efficiency: s.expected > 0 ? (s.actual / s.expected) : null
  }));

  rows.sort((a, b) => (b.efficiency ?? -1) - (a.efficiency ?? -1));

  return {
    rows,
    totalDelivered: orders.length,
    orphanOrders,
    unmatchedDriver,
    activeDrivers: rows.length
  };
}

/* ---------- العرض ---------- */

function fsDriverName(id, driversList) {
  const d = (driversList || []).find(x => x.id === id);
  return d ? d.full_name : 'طيار #' + String(id).slice(0, 6);
}

function renderFairScores(result, driversList, containerId) {
  const el = document.getElementById(containerId);
  if (!result) { el.innerHTML = '<div class="empty-state"><p>خطأ في جلب البيانات</p></div>'; return; }
  if (!result.rows.length) { el.innerHTML = '<div class="empty-state"><p>لا توجد بيانات في هذه الفترة</p></div>'; return; }

  const warn = [];
  if (result.orphanOrders) warn.push(`${result.orphanOrders} طلب اتوصل من غير أي طيار مسجّل حضور وقتها`);
  if (result.unmatchedDriver) warn.push(`${result.unmatchedDriver} طلب من غير طيار محدد`);

  const html = `
    <div class="fs-note">
      إجمالي المسلّم: <strong>${result.totalDelivered}</strong> ·
      طيارين نشطين: <strong>${result.activeDrivers}</strong>
      ${warn.length ? `<div class="fs-warn">⚠ ${warn.join(' — ')}</div>` : ''}
    </div>
    <div class="fs-head">
      <span class="fs-c-name">الطيار</span>
      <span class="fs-c-num">نصيبه</span>
      <span class="fs-c-num">وصّل</span>
      <span class="fs-c-eff">الكفاءة</span>
    </div>
    ${result.rows.map((r, i) => {
      const low = r.actual < FS_MIN_ORDERS;
      const eff = r.efficiency;
      const pct = eff === null ? '—' : Math.round(eff * 100) + '%';
      const cls = eff === null ? 'fs-na' : eff >= 1.1 ? 'fs-great' : eff >= 0.9 ? 'fs-ok' : eff >= 0.7 ? 'fs-mid' : 'fs-low';
      const barW = eff === null ? 0 : Math.min(eff, 1.5) / 1.5 * 100;
      return `<div class="fs-row ${low ? 'fs-dim' : ''}">
        <span class="fs-c-name">
          <span class="fs-rank">${i + 1}</span>${fsDriverName(r.driver_id, driversList)}
          ${low ? '<span class="fs-tag">عينة صغيرة</span>' : ''}
        </span>
        <span class="fs-c-num">${r.expected.toFixed(1)}</span>
        <span class="fs-c-num"><strong>${r.actual}</strong></span>
        <span class="fs-c-eff">
          <span class="fs-bar"><span class="fs-bar-fill ${cls}" style="width:${barW}%"></span></span>
          <span class="fs-pct ${cls}">${pct}</span>
        </span>
      </div>`;
    }).join('')}`;
  el.innerHTML = html;
}
