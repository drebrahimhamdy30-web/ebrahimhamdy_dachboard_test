/**
 * dispatch-engine.js
 * محرك التوزيع التلقائي للطلبات
 */

class DispatchEngine {
  constructor(db, branchId) {
    this.db = db;
    this.branchId = branchId;
    this.settings = null;
    this.isRunning = false;
    this.interval = null;
    this.onLog = null;
  }

  async start() {
    await this.loadSettings();
    if (!this.settings?.auto_dispatch) {
      this.log('التوزيع التلقائي معطّل لهذا الفرع');
      return;
    }
    this.isRunning = true;
    this.log('✅ محرك التوزيع التلقائي شغّال');
    await this.run();
    this.interval = setInterval(() => this.run(), 30000);
  }

  stop() {
    if (this.interval) clearInterval(this.interval);
    this.isRunning = false;
    this.log('⏹ محرك التوزيع التلقائي وقف');
  }

  async loadSettings() {
    try {
      const { data } = await this.db
        .from('dispatch_settings')
        .select('*')
        .eq('branch_id', this.branchId);
      this.settings = data && data.length > 0 ? data[0] : null;
    } catch (e) {
      console.error('loadSettings error:', e);
    }
  }

  async run() {
    if (!this.isRunning) return;
    await this.loadSettings();
    if (!this.settings || !this.settings.auto_dispatch) return;

    this.log('🔄 جاري فحص الطلبات...');
    try {
      const orders = await this.getPendingOrders();
      if (!orders.length) {
        this.log('📭 لا توجد طلبات تحتاج توزيع');
        return;
      }
      this.log('📦 ' + orders.length + ' طلب ينتظر التوزيع');

      const drivers = await this.getAvailableDrivers();
      if (!drivers.length) {
        this.log('👤 لا يوجد طيارين متاحون');
        return;
      }
      this.log('👤 ' + drivers.length + ' طيار متاح');

      const routeMap = await this.buildRouteMap();
      const driverTrips = await this.getDriverCurrentTrips(drivers.map(function(d) { return d.id; }));

      var assigned = 0;
      for (var i = 0; i < orders.length; i++) {
        var result = await this.assignOrder(orders[i], drivers, routeMap, driverTrips);
        if (result) assigned++;
      }
      this.log('✅ تم توزيع ' + assigned + ' طلب');
    } catch (e) {
      console.error('Dispatch engine error:', e);
      this.log('❌ خطأ: ' + e.message);
    }
  }

  async getPendingOrders() {
    var delayMins = this.settings.auto_dispatch_delay_minutes || 5;

    var result = await this.db
      .from('orders')
      .select('*')
      .eq('status', 'pending')
      .is('driver_id', null)
      .order('created_at', { ascending: true });

    var orders = result.data || [];

    // فلتر الوقت في JavaScript
    var cutoff = new Date(Date.now() - delayMins * 60000);
    orders = orders.filter(function(o) {
      var orderTime = new Date(o.bill_date || o.created_at);
      return orderTime <= cutoff;
    });

    // ترتيب حسب الأولوية
    var priority = this.settings.order_priority || 'oldest_first';
    if (priority === 'urgent_first') {
      orders.sort(function(a, b) {
        var aU = (a.notes || '').includes('🚨') ? -1 : 0;
        var bU = (b.notes || '').includes('🚨') ? -1 : 0;
        return aU - bU;
      });
    } else if (priority === 'highest_value') {
      orders.sort(function(a, b) {
        return Number(b.total_bill_net || 0) - Number(a.total_bill_net || 0);
      });
    }

    return orders;
  }

  async getAvailableDrivers() {
    var result = await this.db
      .from('drivers')
      .select('*')
      .eq('is_active', true)
      .eq('is_online', true)
      .eq('branch_id', this.branchId);

    var allDrivers = result.data || [];
    if (!allDrivers.length) return [];

    var driverIds = allDrivers.map(function(d) { return d.id; });

    // استثني اللي في استراحة
    var breaksResult = await this.db
      .from('driver_breaks')
      .select('driver_id')
      .eq('status', 'approved')
      .in('driver_id', driverIds);

    var breakIds = {};
    (breaksResult.data || []).forEach(function(b) { breakIds[b.driver_id] = true; });

    // استثني اللي استلم طلبات
    var pickedResult = await this.db
      .from('orders')
      .select('driver_id')
      .eq('status', 'picked')
      .in('driver_id', driverIds);

    var pickedIds = {};
    (pickedResult.data || []).forEach(function(o) { pickedIds[o.driver_id] = true; });

    return allDrivers.filter(function(d) {
      return !breakIds[d.id] && !pickedIds[d.id];
    });
  }

  async buildRouteMap() {
    var routesResult = await this.db
      .from('routes')
      .select('id, name, branch_id')
      .eq('branch_id', this.branchId)
      .eq('is_active', true);

    var rrResult = await this.db
      .from('route_regions')
      .select('route_id, region_id');

    var regionsResult = await this.db
      .from('regions')
      .select('id, name, types')
      .eq('is_active', true);

    var routeRegions = rrResult.data || [];
    var regions = regionsResult.data || [];
    var routes = routesResult.data || [];

    var map = {};
    regions.forEach(function(region) {
      var regionRoutes = routeRegions
        .filter(function(rr) { return rr.region_id === region.id; })
        .map(function(rr) { return rr.route_id; });

      var key = (region.name || '').trim().toLowerCase();
      map[key] = {
        route_ids: regionRoutes,
        types: region.types || [],
        id: region.id
      };
    });

    return { map: map, routes: routes };
  }

  async getDriverCurrentTrips(driverIds) {
    if (!driverIds.length) return {};

    var tripsResult = await this.db
      .from('trips')
      .select('id, driver_id, route_id, orders_count')
      .eq('status', 'active')
      .in('driver_id', driverIds);

    var pendingResult = await this.db
      .from('orders')
      .select('driver_id')
      .eq('status', 'pending')
      .in('driver_id', driverIds);

    var driverOrderCount = {};
    (pendingResult.data || []).forEach(function(o) {
      driverOrderCount[o.driver_id] = (driverOrderCount[o.driver_id] || 0) + 1;
    });

    var result = {};
    (tripsResult.data || []).forEach(function(trip) {
      result[trip.driver_id] = {
        trip_id: trip.id,
        route_id: trip.route_id,
        order_count: driverOrderCount[trip.driver_id] || 0
      };
    });

    driverIds.forEach(function(id) {
      if (!result[id]) {
        result[id] = { trip_id: null, route_id: null, order_count: 0 };
      }
    });

    return result;
  }

  async assignOrder(order, drivers, routeMap, driverTrips) {
    var regionName = (order.cust_region || '').trim().toLowerCase();
    var regionData = routeMap.map[regionName];

    if (!regionData) {
      this.log('⚠️ منطقة "' + order.cust_region + '" غير مسجلة — تخطي');
      return false;
    }

    var regionRouteIds = regionData.route_ids;
    var needsLicense = regionData.types.includes('permit');

    if (!regionRouteIds.length) {
      this.log('⚠️ منطقة "' + order.cust_region + '" ليست في أي خط سير — تخطي');
      return false;
    }

    var maxOrders = this.settings.max_orders_per_trip || 10;
    var self = this;

    var eligible = drivers.filter(function(driver) {
      if (needsLicense && !driver.has_license) return false;
      var trip = driverTrips[driver.id];
      if (!trip || !trip.trip_id) return true;
      if (trip.route_id && !regionRouteIds.includes(trip.route_id)) return false;
      if (trip.order_count >= maxOrders) return false;
      return true;
    });

    if (!eligible.length) {
      this.log('⏳ لا يوجد طيار متاح لمنطقة "' + order.cust_region + '" — ينتظر');
      return false;
    }

    var driverPriority = this.settings.driver_priority || 'least_orders';
    eligible.sort(function(a, b) {
      return (driverTrips[a.id].order_count || 0) - (driverTrips[b.id].order_count || 0);
    });

    var selectedDriver = eligible[0];
    var trip = driverTrips[selectedDriver.id];
    var now = new Date().toISOString();
    var assignedRouteId = (trip && trip.route_id) ? trip.route_id : regionRouteIds[0];

    try {
      if (trip && trip.trip_id) {
        await this.db.from('orders').update({
          driver_id: selectedDriver.id,
          deliveryman: selectedDriver.full_name,
          updated_at: now
        }).eq('id', order.id);

        await this.db.from('trip_orders').insert({
          trip_id: trip.trip_id,
          order_id: order.id
        });

        await this.db.from('trips').update({
          orders_count: (trip.order_count || 0) + 1,
          updated_at: now
        }).eq('id', trip.trip_id);

        driverTrips[selectedDriver.id].order_count++;

      } else {
        var tripResult = await this.db.from('trips').insert({
          driver_id: selectedDriver.id,
          driver_name: selectedDriver.full_name,
          route_id: assignedRouteId,
          branch_id: this.branchId,
          status: 'active',
          orders_count: 1,
          total_amount: Number(order.total_bill_net || 0),
          created_at: now
        }).select();

        var newTrip = tripResult.data ? tripResult.data[0] : null;

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

          driverTrips[selectedDriver.id] = {
            trip_id: newTrip.id,
            route_id: assignedRouteId,
            order_count: 1
          };

          try {
            await this.db.from('trip_logs').insert({
              trip_id: newTrip.id,
              event: 'trip_created',
              details: { driver: selectedDriver.full_name, auto: true },
              user_name: 'النظام التلقائي'
            });
          } catch(e) {}
        }
      }

      try {
        await this.db.from('order_logs').insert({
          order_id: order.id,
          event: 'driver_assigned',
          details: { driver: selectedDriver.full_name, auto: true },
          user_name: 'النظام التلقائي'
        });
      } catch(e) {}

      this.log('✅ طلب #' + (order.bill_no || order.id.slice(0,8)) + ' → ' + selectedDriver.full_name);
      return true;

    } catch (e) {
      console.error('Assignment error:', e);
      this.log('❌ فشل توزيع طلب #' + order.bill_no + ': ' + e.message);
      return false;
    }
  }

  log(msg) {
    var time = new Date().toLocaleTimeString('ar-EG', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    var full = '[' + time + '] ' + msg;
    console.log(full);
    if (this.onLog) this.onLog(full);
  }
}

if (typeof window !== 'undefined') {
  window.DispatchEngine = DispatchEngine;
}
