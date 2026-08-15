/* ============================================================
   تقييم الطيارين العادل — نصيب مفترض مقابل تسليم فعلي
   يعتمد على: orders.delivered_at + driver_attendance (جلسات online)
   ============================================================ */

const FS_MIN_ORDERS = 5; // حد أدنى لعرض الطيار في الترتيب

// يجيب كل الصفوف مهما كان عددها (يتجاوز حد 1000 صف الافتراضي)
async function _fsFetchAll(buildQuery) {
  const all = []; const size = 1000;
  for (let off = 0; ; off += size) {
    const { data, error } = await buildQuery().range(off, off + size - 1);
    if (error) { console.error(error); break; }
    if (!data || !data.length) break;
    all.push(...data);
    if (data.length < size) break;
  }
  return all;
}

/**
 * يبني فترات الحضور الفعلية من تسلسل أحداث driver_attendance.
 * لا يعتمد على ended_at لأنه غالباً فاضي في البيانات.
 * لكل طيار في كل يوم: online تفتح فترة، وأول offline/break بعدها تقفلها.
 * offline بدون online قبله => يعني كان شغّال من بداية اليوم (شيفت ليلي).
 */
function buildAttendanceSessions(records) {
  // نجمّع حسب الطيار فقط (مش اليوم) عشان الشيفت الليلي اللي بيعدّي منتصف الليل
  // ما يتقطعش. كل سجل online = فترة حضور من approved_at لحد ended_at.
  const byDriver = {};
  records.forEach(r => {
    if (!r.approved_at) return;               // لازم حضور معتمد
    (byDriver[r.driver_id] = byDriver[r.driver_id] || []).push(r);
  });

  const now = Date.now();
  const sessions = [];

  Object.values(byDriver).forEach(recs => {
    recs.sort((a, b) => new Date(a.approved_at) - new Date(b.approved_at));
    recs.forEach((r, i) => {
      if (r.status !== 'online') return;       // نبني الفترات من سجلات online بس
      const driver_id = r.driver_id;
      const start = new Date(r.approved_at).getTime();
      let end;
      if (r.ended_at) {
        // ended_at بيمتد عبر منتصف الليل صح (الشيفت الليلي فترة واحدة متصلة)
        end = new Date(r.ended_at).getTime();
      } else {
        // مفيش ended_at: نقفل عند أول حدث بعده، وإلا الفترة لسه مفتوحة => دلوقتي
        const next = recs[i + 1];
        end = next ? new Date(next.approved_at).getTime() : now;
      }
      if (end > start) sessions.push({ driver_id, start, end });
    });
  });

  return sessions;
}

/**
 * يجيب الطلبات المسلّمة + جلسات الحضور لفترة، ويحسب التقييم.
 * @param {string} from  تاريخ البداية YYYY-MM-DD
 * @param {string} to    تاريخ النهاية YYYY-MM-DD
 * @param {string} branchId  اختياري: فلترة بفرع
 */
async function computeFairScores(from, to, branchId) {
  // نجيب الحضور من يوم قبل البداية — عشان الشيفت الليلي اللي بدأ قبل المدة وطلباته بعد منتصف الليل
  // (الحساب بالشيفت مش باليوم)
  const _attFrom = (() => { const d = new Date(from + 'T00:00:00'); d.setDate(d.getDate() - 1); return d.toISOString().slice(0, 10); })();
  // 1) الطلبات المسلّمة فعلاً في الفترة (نفلتر على delivered_at مش created_at)
  // كل الطلبات وأحداث الحضور مع pagination (يتجاوز حد 1000 صف)
  const [orders, attendanceRows, driversRows] = await Promise.all([
    _fsFetchAll(() => {
      let oq = db.from('orders')
        .select('id,driver_id,deliveryman,delivered_at,picked_at,assigned_at,total_bill_net,status,branch_id')
        .in('status', ['delivered', 'completed'])
        .not('delivered_at', 'is', null)
        .gte('delivered_at', from + 'T00:00:00')
        .lte('delivered_at', to + 'T23:59:59')
        .order('delivered_at', { ascending: true });
      if (branchId) oq = oq.eq('branch_id', branchId);
      return oq;
    }),
    _fsFetchAll(() => db.from('driver_attendance')
      .select('driver_id,status,approved_at,ended_at,date')
      .in('status', ['online', 'offline', 'break'])
      .not('approved_at', 'is', null)
      .gte('date', _attFrom).lte('date', to)
      .order('date', { ascending: true })),
    _fsFetchAll(() => db.from('drivers').select('id,branch_id')),
  ]);

  // خريطة الطيار -> الفرع (عشان نعدّ الحاضرين من نفس فرع الطلب فقط)
  const driverBranch = {};
  (driversRows || []).forEach(d => { driverBranch[d.id] = d.branch_id || null; });

  // فترات الحضور متصلة عبر منتصف الليل (شيفت ليلي) عبر ended_at، وكل فترة معاها فرع الطيار.
  const sessions = buildAttendanceSessions(attendanceRows || []);
  sessions.forEach(s => { s.branch_id = driverBranch[s.driver_id] || null; });

  // 3) لكل طلب: مين كان أونلاين لحظة **استلام** الطلب (مش التسليم)؟
  //    الاستلام بيحصل والطيار حاضر دايمًا، فمافيش داعي لتمديد الشيفت.
  const stats = {};   // driver_id -> { expected, actual, revenue }
  const ensure = id => (stats[id] = stats[id] || { expected: 0, actual: 0, revenue: 0 });

  let orphanOrders = 0;      // طلبات اتوصلت ومفيش حد أونلاين وقتها
  let unmatchedDriver = 0;   // طلبات من غير driver_id

  orders.forEach(o => {
    // وقت المطابقة = وقت الاستلام (الطيار حاضر وقتها أكيد)، وإلا التعيين، وإلا التسليم
    const t = new Date(o.picked_at || o.assigned_at || o.delivered_at).getTime();
    // الحاضرين = طيارين نفس فرع الطلب اللي كانوا أونلاين وقت استلام الطلب
    const online = sessions.filter(s => s.branch_id === o.branch_id && t >= s.start && t < s.end);

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
