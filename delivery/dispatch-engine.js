/**
 * dispatch-engine.js
 * محرك التوزيع التلقائي للطلبات
 * بيشتغل في الخلفية كل X ثانية
 */

class DispatchEngine {
  constructor(db, branchId) {
    this.db = db;
    this.branchId = branchId;
    this.settings = null;
    this.isRunning = false;
    this.interval = null;
    this.onLog = null; // callback للـ UI
  }

  // ===== تشغيل وإيقاف =====
  async start() {
    await this.loadSettings();
    if (!this.settings?.auto_dispatch) {
      this.log('التوزيع التلقائي معطّل لهذا الفرع');
      return;
    }
    this.isRunning = true;
    this.log('✅ محرك التوزيع التلقائي شغّال');
    await this.run(); // تشغيل فوري
    // بعدين كل 30 ثانية
    this.interval = setInterval(() => this.run(), 30000);
  }

  stop() {
    if (this.interval) clearInterval(this.interval);
    this.isRunning = false;
    this.log('⏹ محرك التوزيع التلقائي وقف');
  }

  // ===== تحميل الإعدادات =====
  async loadSettings() {
    const { data } = await this.db
      .from('dispatch_settings')
      .select('*')
      .eq('branch_id', this.branchId);
    this.settings = data?.[0] || null;
  }

  // ===== الدورة الرئيسية =====
  async run() {
    if (!this.isRunning) return;
    await this.loadSettings();
    if (!this.settings?.auto_dispatch) return;

    this.log('🔄 جاري فحص الطلبات...');

    try {
      // 1. جيب الطلبات اللي محتاجة توزيع
      const orders = await this.getPendingOrders();
      if (!orders.length) { this.log('📭 لا توجد طلبات تحتاج توزيع'); return; }
      this.log(`📦 ${orders.length} طلب ينتظر التوزيع`);

      // 2. جيب الطيارين المتاحين
      const drivers = await this.getAvailableDrivers();
      if (!drivers.length) { this.log('👤 لا يوجد طيارين متاحون'); return; }
      this.log(`👤 ${drivers.length} طيار متاح`);

      // 3. جيب خطوط السير والمناطق
      const routeMap = await this.buildRouteMap();

      // 4. جيب رحلات الطيارين الحالية
      const driverTrips = await this.getDriverCurrentTrips(drivers.map(d => d.id));

      // 5. وزّع الطلبات
      let assigned = 0;
      for (const order of orders) {
        const result = await this.assignOrder(order, drivers, routeMap, driverTrips);
        if (result) assigned++;
      }

      this.log(`✅ تم توزيع ${assigned} طلب`);
    } catch (e) {
      console.error('Dispatch engine error:', e);
      this.log('❌ خطأ في محرك التوزيع: ' + e.message);
    }
  }

  // ===== جيب الطلبات اللي تحتاج توزيع =====
  async getPendingOrders() {
    const delayMins = this.settings.auto_dispatch_delay_minutes || 5;
    const cutoff = new Date(Date.now() - delayMins * 60000).toISOString();

    // أولوية الطلبات
    let orderBy = 'created_at';
    if (this.settings.order_priority === 'urgent_first') orderBy = 'notes'; // العاجل له notes تبدأ بـ 🚨
    if (this.settings.order_priority === 'highest_value') orderBy = 'total_bill_net';

    const { data } = await this.db
      .from('orders')
      .select('*')
      .eq('status', 'pending')
      .is('driver_id', null)
      .lte('created_at', cutoff) // انتظر X دقيقة
      .order(orderBy === 'total_bill_net' ? 'total_bill_net' : 'created_at', {
        ascending: orderBy !== 'total_bill_net'
      });

    let orders = data || [];

    // العاجل أولاً
    if (this.settings.order_priority === 'urgent_first') {
      orders.sort((a, b) => {
        const aUrgent = (a.notes || '').includes('🚨') ? -1 : 0;
        const bUrgent = (b.notes || '').includes('🚨') ? -1 : 0;
        return aUrgent - bUrgent;
      });
    }

    return orders;
  }

  // ===== جيب الطيارين المتاحين =====
  async getAvailableDrivers() {
    // الطيارين الأونلاين في نفس الفرع
    const { data: allDrivers } = await this.db
      .from('drivers')
      .select('*')
      .eq('is_active', true)
      .eq('is_online', true)
      .eq('branch_id', this.branchId);

    if (!allDrivers?.length) return [];

    // استثني اللي في استراحة
    const { data: activeBreaks } = await this.db
      .from('driver_breaks')
      .select('driver_id')
      .eq('status', 'approved')
      .in('driver_id', allDrivers.map(d => d.id));

    const breakDriverIds = new Set((activeBreaks || []).map(b => b.driver_id));

    // استثني اللي استلم طلبات (picked)
    const { data: pickedOrders } = await this.db
      .from('orders')
      .select('driver_id')
      .eq('status', 'picked')
      .in('driver_id', allDrivers.map(d => d.id));

    const pickedDriverIds = new Set((pickedOrders || []).map(o => o.driver_id));

    // فلتر: مش في استراحة ومش استلم
    return allDrivers.filter(d =>
      !breakDriverIds.has(d.id) &&
      !pickedDriverIds.has(d.id)
    );
  }

  // ===== بناء خريطة خطوط السير =====
  async buildRouteMap() {
    // { region_name: [route_id1, route_id2, ...] }
    const { data: routes } = await this.db
      .from('routes')
      .select('id, name, branch_id')
      .eq('branch_id', this.branchId)
      .eq('is_active', true);

    const { data: routeRegions } = await this.db
      .from('route_regions')
      .select('route_id, region_id');

    const { data: regions } = await this.db
      .from('regions')
      .select('id, name, types')
      .eq('is_active', true);

    // Map: region_name → { route_ids, types }
    const map = {};
    for (const region of (regions || [])) {
      const regionRoutes = (routeRegions || [])
        .filter(rr => rr.region_id === region.id)
        .map(rr => rr.route_id);

      map[region.name.trim().toLowerCase()] = {
        route_ids: regionRoutes,
        types: region.types || [],
        id: region.id
      };
    }

    return { map, routes: routes || [] };
  }

  // ===== جيب رحلات الطيارين الحالية =====
  async getDriverCurrentTrips(driverIds) {
    if (!driverIds.length) return {};

    const { data: trips } = await this.db
      .from('trips')
      .select('id, driver_id, route_id, orders_count')
      .eq('status', 'active')
      .in('driver_id', driverIds);

    // عدد الطلبات الحالية لكل طيار
    const { data: pendingOrders } = await this.db
      .from('orders')
      .select('driver_id')
      .eq('status', 'pending')
      .in('driver_id', driverIds);

    const driverOrderCount = {};
    for (const o of (pendingOrders || [])) {
      driverOrderCount[o.driver_id] = (driverOrderCount[o.driver_id] || 0) + 1;
    }

    // { driver_id: { trip_id, route_id, order_count } }
    const result = {};
    for (const trip of (trips || [])) {
      result[trip.driver_id] = {
        trip_id: trip.id,
        route_id: trip.route_id,
        order_count: driverOrderCount[trip.driver_id] || 0
      };
    }

    // الطيارين الفاضيين
    for (const id of driverIds) {
      if (!result[id]) {
        result[id] = {
          trip_id: null,
          route_id: null,
          order_count: 0
        };
      }
    }

    return result;
  }

  // ===== توزيع طلب واحد =====
  async assignOrder(order, drivers, routeMap, driverTrips) {
    const regionName = (order.cust_region || '').trim().toLowerCase();
    const regionData = routeMap.map[regionName];

    if (!regionData) {
      this.log(`⚠️ منطقة "${order.cust_region}" غير مسجلة في النظام — تخطي`);
      return false;
    }

    const regionRouteIds = regionData.route_ids;
    const needsLicense = regionData.types.includes('permit');

    if (!regionRouteIds.length) {
      this.log(`⚠️ منطقة "${order.cust_region}" ليست في أي خط سير — تخطي`);
      return false;
    }

    // فلتر الطيارين المناسبين
    let eligibleDrivers = drivers.filter(driver => {
      // ترخيص
      if (needsLicense && !driver.has_license) return false;

      const trip = driverTrips[driver.id];

      // الطيار فاضي — يقبل أي خط سير
      if (!trip?.trip_id) return true;

      // الطيار عنده رحلة — لازم نفس خط السير
      if (trip.route_id && !regionRouteIds.includes(trip.route_id)) return false;

      // ما وصلش الحد الأقصى
      const maxOrders = this.settings.max_orders_per_trip || 10;
      if (trip.order_count >= maxOrders) return false;

      return true;
    });

    if (!eligibleDrivers.length) {
      this.log(`⏳ لا يوجد طيار متاح لمنطقة "${order.cust_region}" — الطلب ينتظر`);
      return false;
    }

    // ترتيب حسب الأولوية
    if (this.settings.driver_priority === 'least_orders') {
      eligibleDrivers.sort((a, b) =>
        (driverTrips[a.id]?.order_count || 0) - (driverTrips[b.id]?.order_count || 0)
      );
    } else if (this.settings.driver_priority === 'longest_idle') {
      // الطيار الأطول وقت بدون طلب — الأقل order_count وعنده trip قديمة
      eligibleDrivers.sort((a, b) =>
        (driverTrips[a.id]?.order_count || 0) - (driverTrips[b.id]?.order_count || 0)
      );
    }

    const selectedDriver = eligibleDrivers[0];
    const trip = driverTrips[selectedDriver.id];
    const now = new Date().toISOString();
    const maxOrders = this.settings.max_orders_per_trip || 10;

    // حدد الـ route_id المناسب
    let assignedRouteId = trip?.route_id || regionRouteIds[0];

    try {
      if (trip?.trip_id) {
        // أضف لرحلة موجودة
        await this.db.from('orders').update({
          driver_id: selectedDriver.id,
          deliveryman: selectedDriver.full_name,
          status: 'pending', // يفضل pending لحد ما الطيار يستلم
          updated_at: now
        }).eq('id', order.id);

        await this.db.from('trip_orders').insert({
          trip_id: trip.trip_id,
          order_id: order.id
        });

        // حدّث عدد الطلبات في الرحلة
        await this.db.from('trips').update({
          orders_count: (trip.order_count || 0) + 1,
          total_amount: await this.getTripTotal(trip.trip_id, order.total_bill_net),
          updated_at: now
        }).eq('id', trip.trip_id);

        // حدّث الـ driverTrips في الميموري
        driverTrips[selectedDriver.id].order_count++;

      } else {
        // أنشئ رحلة جديدة
        const { data: newTrip } = await this.db.from('trips').insert({
          driver_id: selectedDriver.id,
          driver_name: selectedDriver.full_name,
          route_id: assignedRouteId,
          branch_id: this.branchId,
          status: 'active',
          orders_count: 1,
          total_amount: Number(order.total_bill_net || 0),
          created_at: now
        }).select().single();

        if (newTrip) {
          await this.db.from('trip_orders').insert({
            trip_id: newTrip.id,
            order_id: order.id
          });

          await this.db.from('orders').update({
            driver_id: selectedDriver.id,
            deliveryman: selectedDriver.full_name,
            updated_at: now
          }).eq('id', order.id);

          // حدّث الـ driverTrips في الميموري
          driverTrips[selectedDriver.id] = {
            trip_id: newTrip.id,
            route_id: assignedRouteId,
            order_count: 1
          };

          // سجّل في trip_logs
          await this.db.from('trip_logs').insert({
            trip_id: newTrip.id,
            event: 'trip_created',
            details: { driver: selectedDriver.full_name, auto: true },
            user_name: 'النظام التلقائي'
          });
        }
      }

      // سجّل في order_logs
      await this.db.from('order_logs').insert({
        order_id: order.id,
        event: 'driver_assigned',
        details: {
          driver: selectedDriver.full_name,
          auto: true,
          route_id: assignedRouteId
        },
        user_name: 'النظام التلقائي'
      });

      this.log(`✅ طلب #${order.bill_no || order.id.slice(0,8)} → ${selectedDriver.full_name}`);
      return true;

    } catch (e) {
      console.error('Assignment error:', e);
      this.log(`❌ فشل توزيع طلب #${order.bill_no}: ${e.message}`);
      return false;
    }
  }

  // ===== مجموع الرحلة =====
  async getTripTotal(tripId, newOrderAmount) {
    const { data: orders } = await this.db
      .from('trip_orders')
      .select('orders(total_bill_net)')
      .eq('trip_id', tripId);

    const existing = (orders || []).reduce((s, o) =>
      s + Number(o.orders?.total_bill_net || 0), 0
    );
    return existing + Number(newOrderAmount || 0);
  }

  // ===== Log =====
  log(msg) {
    const time = new Date().toLocaleTimeString('ar-EG', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    const full = `[${time}] ${msg}`;
    console.log(full);
    if (this.onLog) this.onLog(full);
  }
}

// Export للاستخدام في الصفحات
if (typeof window !== 'undefined') {
  window.DispatchEngine = DispatchEngine;
}
