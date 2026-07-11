/**
 * dispatch-engine.js
 * محرك التوزيع التلقائي - نسخة التقاطع
 *
 * القواعد:
 * - الطيار عنده رحلة واحدة active بس.
 * - لكل أوردر: مجموعة خطوط سير منطقته (route_set).
 *     منطقة بخطوط رسمية → {route:<id>, ...}
 *     منطقة بدون خطوط   → {region:<name>}
 *     بدون منطقة        → {none}
 * - رحلة الطيار ليها مجموعة خطوط = اتحاد خطوط كل أوردراتها (تتمدد).
 * - الأوردر ينضاف على رحلة الطيار لو:
 *     فيه تقاطع بين route_set بتاع الأوردر و route_set بتاع الرحلة
 *     + الرحلة لسه أقل من max_orders_per_trip.
 * - غير كده → طيار متاح جديد، أو ينتظر.
 */

class DispatchEngine {
  constructor(db, branchId) {
    this.db = db;
    this.branchId = branchId;
    this.settings = null;
    this.isRunning = false;
    this._interval = null;
    this.onLog = null;
    this._isBusy = false; // منع تداخل دورتين تشغيل فوق بعض
  }

  _sleep(ms) {
    return new Promise(function(resolve){ setTimeout(resolve, ms); });
  }

  stop() {
    this.isRunning = false;
    if (this._interval) { clearInterval(this._interval); this._interval = null; }
    this.log('🛑 تم إيقاف محرك التوزيع');
  }

  async start() {
    await this.loadSettings();
    if (!this.settings || !this.settings.auto_dispatch) {
      this.log('التوزيع التلقائي معطّل لهذا الفرع');
      return;
    }
    this.isRunning = true;
    this.log('✅ محرك التوزيع التلقائي شغّال');
    await this.run();
    var intervalMs = ((this.settings.engine_interval_minutes || 1) * 60000);
    this._interval = setInterval(function(self) { self.run(); }, intervalMs, this);
  }

  async loadSettings() {
    try {
      var result = await this.db
        .from('dispatch_settings')
        .select('*')
        .eq('branch_id', this.branchId);
      this.settings = result.data && result.data.length > 0 ? result.data[0] : null;
    } catch(e) { console.error('loadSettings error:', e); }
  }

async run() {
    if (!this.isRunning) return;

    // منع تشغيل دورتين فوق بعض (لو الدورة القديمة لسه بتستنى بين الطلبات)
    if (this._isBusy) {
      this.log('⏸ الدورة السابقة لسه شغالة — تم تخطي هذه الدورة');
      return;
    }
    this._isBusy = true;

    try {
      await this.loadSettings();
      if (!this.settings || !this.settings.auto_dispatch) {
        this.stop();
        return;
      }

      this.log('🔄 جاري فحص الطلبات...');

      // رجّع الطلبات المؤجلة اللي عدّى وقتها أولاً — قبل أي return
      await this.activateDuePostponed();

      var orders = await this.getPendingOrders();
      if (!orders.length) { this.log('📭 لا توجد طلبات تحتاج توزيع'); return; }
      this.log('📦 ' + orders.length + ' طلب ينتظر التوزيع');

      var drivers = await this.getAvailableDrivers();
      if (!drivers.length) { this.log('👤 لا يوجد طيارين متاحون'); return; }
      this.log('👤 ' + drivers.length + ' طيار متاح');

      var routeMap = await this.buildRouteMap();
      var driverActiveTrip = await this.getDriverActiveTrip(drivers.map(function(d){return d.id;}), routeMap);

      // الفاصل بالثواني بين توزيع كل طلب والتالي
      var staggerMs = (this.settings.stagger_seconds || 5) * 1000;

      var assigned = 0;
      for (var i = 0; i < orders.length; i++) {
        if (!this.isRunning) break; // لو الـ Engine اتوقف وسط الدورة، يقف فوراً

        var ok = await this.assignOrder(orders[i], drivers, routeMap, driverActiveTrip);
        if (ok) {
          assigned++;
          // استنى قبل ما توزّع اللي بعده (لو فيه طلبات لسه)
          if (i < orders.length - 1) {
            this.log('⏳ انتظار ' + (staggerMs/1000) + ' ثانية قبل توزيع الطلب التالي...');
            await this._sleep(staggerMs);
          }
        }
      }
      this.log('✅ تم توزيع ' + assigned + ' طلب');

    } catch(e) {
      console.error('Engine error:', e);
      this.log('❌ خطأ: ' + e.message);
    } finally {
      this._isBusy = false;
    }
  }
  async activateDuePostponed() {
    try {
      const now = new Date().toISOString();
      // الطلبات المؤجلة اللي عدّى وقتها (نفس منطق الأمر اليدوي المُجرّب)
      const dueRes = await this.db
        .from('orders')
        .select('id, bill_no, postpone_time, attempt_count')
        .eq('status', 'postponed')
        .lte('postpone_time', now);
      // الطلبات المؤجلة بدون وقت محدد (ترجع فوراً)
      const nullRes = await this.db
        .from('orders')
        .select('id, bill_no, postpone_time, attempt_count')
        .eq('status', 'postponed')
        .is('postpone_time', null);
      const result = { data: [...(dueRes.data||[]), ...(nullRes.data||[])] };
      const maxAttempts = this.settings.max_attempts || 3;
      const orders = (result.data || []).filter(o =>
        !o.attempt_count || o.attempt_count < maxAttempts
      );

      if (!orders.length) return;

      const ids = orders.map(o => o.id);
      await this.db.from('orders').update({
        status: 'pending',
        postpone_reason: null,
        driver_id: null,
        deliveryman: null,
        assigned_at: null,
        picked_at: null,
        updated_at: now
      }).in('id', ids);

      this.log('🔄 تم تشغيل ' + orders.length + ' طلب مؤجل');
    } catch(e) {
      console.error('activateDuePostponed error:', e);
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
    var cutoff = new Date(Date.now() - delayMins * 60000);
    orders = orders.filter(function(o) {
      var bd = o.bill_date ? new Date(new Date(o.bill_date).getTime()-2*60*60*1000) : new Date(o.created_at);
      return bd <= cutoff;
    });

    var priority = this.settings.order_priority || 'oldest_first';
    if (priority === 'urgent_first') {
      orders.sort(function(a, b) {
        var aU = (a.notes||'').includes('🚨') ? -1 : 0;
        var bU = (b.notes||'').includes('🚨') ? -1 : 0;
        return aU - bU;
      });
    } else if (priority === 'highest_value') {
      orders.sort(function(a, b) {
        return Number(b.total_bill_net||0) - Number(a.total_bill_net||0);
      });
    }
    return orders;
  }

  async getAvailableDrivers() {
    var result = await this.db
      .from('drivers')
      .select('*')
      .eq('is_active', true)
      .eq('branch_id', this.branchId);

    var allDrivers = result.data || [];
    if (!allDrivers.length) return [];
    var driverIds = allDrivers.map(function(d){return d.id;});

// آخر حالة حضور لكل طيار — مهما كان تاريخها (مش بس النهاردة)
    var attRes = await this.db
      .from('driver_attendance')
      .select('driver_id, status, created_at')
      .in('driver_id', driverIds)
      .order('created_at', {ascending: false})
      .limit(500);

    var attStatus = {};
    (attRes.data||[]).forEach(function(r){
      if(!attStatus[r.driver_id]) attStatus[r.driver_id] = r.status;
    });

    var presentDrivers = allDrivers.filter(function(d){
      return attStatus[d.id] === 'online';
    });

    if (!presentDrivers.length) {
      presentDrivers = allDrivers.filter(function(d){ return d.is_online; });
    }

    if (!presentDrivers.length) return [];
    var presentIds = presentDrivers.map(function(d){return d.id;});

var pickedRes = await this.db
      .from('orders')
      .select('driver_id')
      .in('status', ['picked', 'failed'])
      .in('driver_id', presentIds);
    var pickedIds = {};
    (pickedRes.data||[]).forEach(function(o){pickedIds[o.driver_id]=true;});

    return presentDrivers.filter(function(d){
      return !pickedIds[d.id];
    });
  }

  async buildRouteMap() {
    var routesRes = await this.db
      .from('routes')
      .select('id, name')
      .eq('branch_id', this.branchId)
      .eq('is_active', true);

    var rrRes = await this.db.from('route_regions').select('route_id, region_id');
   var regRes = await this.db.from('regions').select('id, name, types').eq('is_active', true).eq('branch_id', this.branchId);

    var routeRegions = rrRes.data || [];
    var regions = regRes.data || [];

    var map = {};
    regions.forEach(function(region) {
      var rids = routeRegions
        .filter(function(rr){return rr.region_id === region.id;})
        .map(function(rr){return rr.route_id;});
      var key = (region.name||'').trim().toLowerCase();
      if (map[key]) {
        rids.forEach(function(id){ if(map[key].route_ids.indexOf(id)<0) map[key].route_ids.push(id); });
      } else {
        map[key] = { route_ids: rids.slice(), types: region.types||[], id: region.id };
      }
    });

    return { map: map, routes: routesRes.data || [] };
  }

  getOrderRouteSet(order, routeMap) {
    var regionName = (order.cust_region||'').trim().toLowerCase();
    if (!regionName) {
      return { set: new Set(['none']), region_data: null, unregistered: false };
    }
    var rd = routeMap.map[regionName];
    if (!rd) {
      return { set: new Set(['region:' + regionName]), region_data: null, unregistered: true };
    }
    if (rd.route_ids && rd.route_ids.length) {
      var s = new Set(rd.route_ids.map(function(id){ return 'route:' + id; }));
      return { set: s, region_data: rd, unregistered: false };
    }
    return { set: new Set(['region:' + regionName]), region_data: rd, unregistered: false };
  }

  _intersects(setA, setB) {
    for (var x of setA) { if (setB.has(x)) return true; }
    return false;
  }

  async getDriverActiveTrip(driverIds, routeMap) {
    if (!driverIds.length) return {};
    if (!routeMap) routeMap = await this.buildRouteMap();

    var tripsRes = await this.db
      .from('trips')
      .select('id, driver_id, route_id, created_at')
      .eq('status', 'active')
      .order('created_at', { ascending: true });

    var trips = (tripsRes.data || []).filter(function(t){
      return driverIds.includes(t.driver_id);
    });

    var result = {};
    trips.forEach(function(trip){
      if (!result[trip.driver_id]) {
        result[trip.driver_id] = { trip_id: trip.id, route_id: trip.route_id, order_count: 0, route_set: new Set() };
      }
    });

    var tripIds = Object.keys(result).map(function(did){ return result[did].trip_id; });
    if (!tripIds.length) {
      driverIds.forEach(function(id){ if(!result[id]) result[id] = { trip_id: null, route_id: null, order_count: 0, route_set: new Set() }; });
      return result;
    }

    var toRes = await this.db
      .from('trip_orders')
      .select('trip_id, order_id')
      .in('trip_id', tripIds);

    var tripOrderIds = {};
    (toRes.data||[]).forEach(function(to){
      if(!tripOrderIds[to.trip_id]) tripOrderIds[to.trip_id] = [];
      tripOrderIds[to.trip_id].push(to.order_id);
    });

    var allOrderIds = (toRes.data||[]).map(function(to){return to.order_id;});
    var ordersById = {};
    if (allOrderIds.length) {
      var ordRes = await this.db
        .from('orders')
        .select('id, cust_region')
        .in('id', allOrderIds);
      (ordRes.data||[]).forEach(function(o){ ordersById[o.id] = o; });
    }

    var self = this;
    Object.keys(result).forEach(function(did){
      var t = result[did];
      var oids = tripOrderIds[t.trip_id] || [];
      t.order_count = oids.length;
      oids.forEach(function(oid){
        var ord = ordersById[oid];
        if (!ord) return;
        var rs = self.getOrderRouteSet(ord, routeMap).set;
        rs.forEach(function(x){ t.route_set.add(x); });
      });
    });

    driverIds.forEach(function(id){
      if(!result[id]) result[id] = { trip_id: null, route_id: null, order_count: 0, route_set: new Set() };
    });

    return result;
  }

  async assignOrder(order, drivers, routeMap, driverActiveTrip) {
    var ors = this.getOrderRouteSet(order, routeMap);
    var orderSet = ors.set;
    var regionData = ors.region_data;
    var needsLicense = regionData ? (regionData.types||[]).includes('permit') : false;

    if (ors.unregistered) {
      this.log('⚠️ منطقة "' + order.cust_region + '" غير مسجلة — تُعامل كخط مستقل');
    }

    var maxOrders = this.settings.max_orders_per_trip || 10;
    var self = this;

    var eligible = drivers.filter(function(driver) {
      if (regionData) {
        var regionTypes = regionData.types || [];
        var coveredTypes = driver.covered_types || [];
        if (regionTypes.length > 0 && coveredTypes.length > 0) {
          var hasMatch = regionTypes.some(function(t){ return coveredTypes.includes(t); });
          if (!hasMatch) return false;
        }
      }
      if (needsLicense && !driver.has_vehicle_license && !driver.has_drive_license) return false;

      var trip = driverActiveTrip[driver.id];

      if (trip && trip.trip_id) {
        if ((trip.order_count || 0) >= maxOrders) return false;
        if (trip.route_set && trip.route_set.size > 0) {
          if (!self._intersects(orderSet, trip.route_set)) return false;
        }
        return true;
      }

      return true;
    });

    if (!eligible.length) {
      this.log('⏳ لا يوجد طيار متاح' + (order.cust_region ? ' لمنطقة "' + order.cust_region + '"' : '') + ' — ينتظر');
      return false;
    }

    eligible.sort(function(a, b) {
      var ac = driverActiveTrip[a.id] ? (driverActiveTrip[a.id].order_count||0) : 0;
      var bc = driverActiveTrip[b.id] ? (driverActiveTrip[b.id].order_count||0) : 0;
      return ac - bc;
    });

    var selectedDriver = eligible[0];
    var trip = driverActiveTrip[selectedDriver.id];
    var now = new Date().toISOString();
    var firstRouteId = null;
    for (var x of orderSet) { if (x.indexOf('route:')===0) { firstRouteId = x.slice(6); break; } }
    var assignedRouteId = (trip && trip.route_id) ? trip.route_id : firstRouteId;

    try {
      if (trip && trip.trip_id) {
        await this.db.from('orders').update({
          driver_id: selectedDriver.id,
          deliveryman: selectedDriver.full_name,
          status: 'assigned',
          assigned_at: now,
          updated_at: now
        }).eq('id', order.id);

        await this.db.from('trip_orders').insert({ trip_id: trip.trip_id, order_id: order.id });
        await this.db.from('trips').update({ orders_count: (trip.order_count||0)+1, updated_at: now }).eq('id', trip.trip_id);

        driverActiveTrip[selectedDriver.id].order_count = (trip.order_count||0)+1;
        orderSet.forEach(function(x){ driverActiveTrip[selectedDriver.id].route_set.add(x); });

      } else {
        var tripRes = await this.db.from('trips').insert({
          driver_id: selectedDriver.id,
          driver_name: selectedDriver.full_name,
          route_id: assignedRouteId,
          branch_id: this.branchId,
          status: 'active',
          orders_count: 1,
          total_amount: Number(order.total_bill_net || 0),
          created_at: now
        }).select();

        var newTrip = tripRes.data ? tripRes.data[0] : null;
        if (!newTrip) { this.log('❌ فشل إنشاء الرحلة'); return false; }

        await this.db.from('trip_orders').insert({ trip_id: newTrip.id, order_id: order.id });
        await this.db.from('orders').update({
          driver_id: selectedDriver.id,
          deliveryman: selectedDriver.full_name,
          status: 'assigned',
          assigned_at: now,
          updated_at: now
        }).eq('id', order.id);

        driverActiveTrip[selectedDriver.id] = {
          trip_id: newTrip.id,
          route_id: assignedRouteId,
          order_count: 1,
          route_set: new Set(orderSet)
        };

        try {
          await this.db.from('trip_logs').insert({
            trip_id: newTrip.id, event: 'trip_created',
            details: { driver: selectedDriver.full_name, auto: true },
            user_name: 'النظام التلقائي'
          });
        } catch(e) {}
      }

      try {
        await this.db.from('order_logs').insert({
          order_id: order.id, event: 'driver_assigned',
          details: { driver: selectedDriver.full_name, auto: true, route: assignedRouteId },
          user_name: 'النظام التلقائي'
        });
      } catch(e) {}

      this.log('✅ طلب #' + (order.bill_no||order.id.slice(0,8)) + ' → ' + selectedDriver.full_name);
      return true;

    } catch(e) {
      console.error('Assignment error:', e);
      this.log('❌ فشل: ' + e.message);
      return false;
    }
  }

  log(msg) {
    var time = new Date().toLocaleTimeString('ar-EG', {hour:'2-digit', minute:'2-digit', second:'2-digit'});
    var full = '[' + time + '] ' + msg;
    console.log(full);
    if (this.onLog) this.onLog(full);
  }
}

if (typeof window !== 'undefined') { window.DispatchEngine = DispatchEngine; }
