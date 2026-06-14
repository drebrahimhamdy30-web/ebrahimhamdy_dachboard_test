/**
 * dispatch-engine.js
 * محرك التوزيع التلقائي - نسخة مُصلَّحة
 *
 * القواعد:
 * - الطيار عنده رحلة واحدة active بس.
 * - الرحلة بتتثبّت على "مفتاح خط سير" (route_key) أول طلب فيها:
 *     خط السير الرسمي لو موجود، وإلا اسم المنطقة نفسها.
 * - طلب جديد ينضاف على رحلة الطيار فقط لو:
 *     نفس route_key  +  الرحلة لسه أقل من max_orders_per_trip.
 * - غير كده → يروح لطيار تاني متاح (أو يستنى).
 */

class DispatchEngine {
  constructor(db, branchId) {
    this.db = db;
    this.branchId = branchId;
    this.settings = null;
    this.isRunning = false;
    this._interval = null;
    this.onLog = null;
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
    await this.loadSettings();
    if (!this.settings || !this.settings.auto_dispatch) {
      this.stop();
      return;
    }

    this.log('🔄 جاري فحص الطلبات...');
    try {
      var orders = await this.getPendingOrders();
      if (!orders.length) { this.log('📭 لا توجد طلبات تحتاج توزيع'); return; }
      this.log('📦 ' + orders.length + ' طلب ينتظر التوزيع');

      var drivers = await this.getAvailableDrivers();
      if (!drivers.length) { this.log('👤 لا يوجد طيارين متاحون'); return; }
      this.log('👤 ' + drivers.length + ' طيار متاح');

      var routeMap = await this.buildRouteMap();
      // حالة رحلة كل طيار (رحلة واحدة بس لكل طيار)
      var driverActiveTrip = await this.getDriverActiveTrip(drivers.map(function(d){return d.id;}), routeMap);

      var assigned = 0;
      for (var i = 0; i < orders.length; i++) {
        var ok = await this.assignOrder(orders[i], drivers, routeMap, driverActiveTrip);
        if (ok) assigned++;
      }
      this.log('✅ تم توزيع ' + assigned + ' طلب');

      await this.activateDuePostponed();

    } catch(e) {
      console.error('Engine error:', e);
      this.log('❌ خطأ: ' + e.message);
    }
  }

  async activateDuePostponed() {
    try {
      const now = new Date().toISOString();
      const result = await this.db
        .from('orders')
        .select('id, bill_no, postpone_time, attempt_count')
        .eq('status', 'postponed')
        .or(`postpone_time.lte.${now},postpone_time.is.null`);

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

    var today = new Date().toISOString().split('T')[0];
    var attRes = await this.db
      .from('driver_attendance')
      .select('driver_id, status, created_at')
      .eq('date', today)
      .in('driver_id', driverIds)
      .order('created_at', {ascending: false});

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

    // استثني اللي استلم (picked) — مشغول في توصيل
    var pickedRes = await this.db
      .from('orders')
      .select('driver_id')
      .eq('status', 'picked')
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
    var regRes = await this.db.from('regions').select('id, name, types').eq('is_active', true);

    var routeRegions = rrRes.data || [];
    var regions = regRes.data || [];

    var map = {};
    regions.forEach(function(region) {
      var rids = routeRegions
        .filter(function(rr){return rr.region_id === region.id;})
        .map(function(rr){return rr.route_id;});
      var key = (region.name||'').trim().toLowerCase();
      map[key] = { route_ids: rids, types: region.types||[], id: region.id };
    });

    return { map: map, routes: routesRes.data || [] };
  }

  /**
   * مفتاح خط السير لطلب معيّن:
   * - لو المنطقة مربوطة بخط سير رسمي → 'route:' + أول route_id
   * - لو منطقة موجودة بس بدون خط سير رسمي → 'region:' + اسم المنطقة
   * - لو مفيش منطقة خالص → 'none'
   */
  getOrderRouteKey(order, routeMap) {
    var regionName = (order.cust_region||'').trim().toLowerCase();
    if (!regionName) return { key: 'none', route_id: null, region_data: null, unregistered: false };
    var rd = routeMap.map[regionName];
    if (!rd) {
      // منطقة غير مسجلة خالص → تُعامل كخط سير قائم بذاته باسمها
      return { key: 'region:' + regionName, route_id: null, region_data: null, unregistered: true };
    }
    if (rd.route_ids && rd.route_ids.length) {
      return { key: 'route:' + rd.route_ids[0], route_id: rd.route_ids[0], region_data: rd, unregistered: false };
    }
    // منطقة مسجلة بس مالهاش خط سير رسمي → تُعامل كخط سير باسمها
    return { key: 'region:' + regionName, route_id: null, region_data: rd, unregistered: false };
  }

  /**
   * رحلة الطيار الحالية (الطيار عنده رحلة active واحدة بس).
   * بنرجّع لكل طيار: trip_id, route_key, order_count.
   * route_key بنحسبه من أول طلب في الرحلة.
   */
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
    // الطيار عنده رحلة واحدة بس — ناخد الأقدم لو (استثناءً) لقينا أكتر
    trips.forEach(function(trip){
      if (!result[trip.driver_id]) {
        result[trip.driver_id] = { trip_id: trip.id, route_id: trip.route_id, order_count: 0, route_key: null, first_order_region: null };
      }
    });

    var tripIds = Object.keys(result).map(function(did){ return result[did].trip_id; });
    if (!tripIds.length) {
      driverIds.forEach(function(id){ if(!result[id]) result[id] = { trip_id: null, route_id: null, order_count: 0, route_key: null }; });
      return result;
    }

    // اجمع طلبات كل رحلة عشان نحسب العدد ومفتاح خط السير من أول طلب
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
        .select('id, cust_region, created_at')
        .in('id', allOrderIds);
      (ordRes.data||[]).forEach(function(o){ ordersById[o.id] = o; });
    }

    var self = this;
    Object.keys(result).forEach(function(did){
      var t = result[did];
      var oids = tripOrderIds[t.trip_id] || [];
      t.order_count = oids.length;
      // أول طلب (الأقدم) يحدد مفتاح خط السير للرحلة
      var firstOrder = oids
        .map(function(id){ return ordersById[id]; })
        .filter(Boolean)
        .sort(function(a,b){ return new Date(a.created_at) - new Date(b.created_at); })[0];
      if (firstOrder) {
        t.route_key = self.getOrderRouteKey(firstOrder, routeMap).key;
      } else if (t.route_id) {
        t.route_key = 'route:' + t.route_id;
      }
    });

    driverIds.forEach(function(id){
      if(!result[id]) result[id] = { trip_id: null, route_id: null, order_count: 0, route_key: null };
    });

    return result;
  }

  async assignOrder(order, drivers, routeMap, driverActiveTrip) {
    var rk = this.getOrderRouteKey(order, routeMap);
    var orderRouteKey = rk.key;
    var regionData = rk.region_data;
    var needsLicense = regionData ? (regionData.types||[]).includes('permit') : false;

    if (rk.unregistered) {
      this.log('⚠️ منطقة "' + order.cust_region + '" غير مسجلة — تُعامل كخط سير مستقل');
    }

    var maxOrders = this.settings.max_orders_per_trip || 10;

    var self = this;
    var eligible = drivers.filter(function(driver) {
      // التصنيفات المغطاة (لو المنطقة مسجلة وعندها تصنيف)
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

      // الطيار عنده رحلة active:
      if (trip && trip.trip_id) {
        // لازم نفس مفتاح خط السير
        if (trip.route_key && trip.route_key !== orderRouteKey) return false;
        // ولازم الرحلة لسه أقل من الحد
        if ((trip.order_count || 0) >= maxOrders) return false;
        return true;
      }

      // الطيار مفيش عنده رحلة → متاح لأي خط سير
      return true;
    });

    if (!eligible.length) {
      this.log('⏳ لا يوجد طيار متاح' + (order.cust_region ? ' لمنطقة "' + order.cust_region + '"' : '') + ' — ينتظر');
      return false;
    }

    // الأولوية: الأقل طلبات أولاً
    eligible.sort(function(a, b) {
      var ac = driverActiveTrip[a.id] ? (driverActiveTrip[a.id].order_count||0) : 0;
      var bc = driverActiveTrip[b.id] ? (driverActiveTrip[b.id].order_count||0) : 0;
      return ac - bc;
    });

    var selectedDriver = eligible[0];
    var trip = driverActiveTrip[selectedDriver.id];
    var now = new Date().toISOString();
    var assignedRouteId = rk.route_id || (trip && trip.route_id) || null;

    try {
      if (trip && trip.trip_id) {
        // أضف على الرحلة الموجودة
        await this.db.from('orders').update({
          driver_id: selectedDriver.id,
          deliveryman: selectedDriver.full_name,
          status: 'assigned',
          assigned_at: now,
          updated_at: now
        }).eq('id', order.id);

        await this.db.from('trip_orders').insert({ trip_id: trip.trip_id, order_id: order.id });
        await this.db.from('trips').update({ orders_count: (trip.order_count||0)+1, updated_at: now }).eq('id', trip.trip_id);

        // حدّث الحالة في الذاكرة
        driverActiveTrip[selectedDriver.id].order_count = (trip.order_count||0)+1;
        if (!driverActiveTrip[selectedDriver.id].route_key) {
          driverActiveTrip[selectedDriver.id].route_key = orderRouteKey;
        }

      } else {
        // أنشئ رحلة جديدة (أول طلب يثبّت مفتاح خط السير)
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
          route_key: orderRouteKey
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
