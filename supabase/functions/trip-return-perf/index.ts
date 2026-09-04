import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// نداء Google Routes واحد لكل الرحلة: الصيدلية -> كل نقاط التسليم (waypoints) -> الصيدلية.
// نستخرج من الـlegs مسافة/زمن كل طلب (perf_rating + distance) + رحلة العودة — بدل نداء لكل طلب.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const TRAVEL_MODE = "TWO_WHEELER";
const SB_URL = Deno.env.get("SUPABASE_URL");
const SRK = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const GKEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";

// ⚠️ السر مايتكتبش في الكود — من vault. الدالة دي بتنادى من تريجرات
// القاعدة بس (مش من تطبيق السواقين)، فسرها اتغيّر لوحده.
// بنقبل سر التطبيق القديم كمان فترة انتقالية عشان مايبقاش فيه لحظة انقطاع.
let _sec: { a: string; b: string; exp: number } | null = null;
async function secrets(): Promise<{ a: string; b: string }> {
  const now = Date.now();
  if (_sec && _sec.exp > now) return _sec;
  const get = async (n: string) => {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/vault_secret`, {
      method: "POST",
      headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_name: n }),
    });
    if (!r.ok) return "";
    const v = await r.json();
    return typeof v === "string" ? v : "";
  };
  const a = await get("perf_functions_secret");
  const b = await get("driver_app_secret");
  _sec = { a, b, exp: now + 60000 };
  return _sec;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
async function sbGet(path) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { headers: { apikey: SRK, Authorization: `Bearer ${SRK}` } });
  if (!r.ok) return [];
  return await r.json();
}
async function sbPatch(path, body) {
  await fetch(`${SB_URL}/rest/v1/${path}`, {
    method: "PATCH",
    headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json", Prefer: "return=minimal" },
    body: JSON.stringify(body),
  });
}

// نداء واحد بكل نقاط التوقف؛ يرجّع مصفوفة legs (قطعة بين كل نقطتين متتاليتين)
async function googleTripRoute(pharmacy, stops) {
  const reqBody = {
    origin: { location: { latLng: { latitude: pharmacy.lat, longitude: pharmacy.lng } } },
    destination: { location: { latLng: { latitude: pharmacy.lat, longitude: pharmacy.lng } } },
    intermediates: stops.map((s) => ({ location: { latLng: { latitude: s.lat, longitude: s.lng } } })),
    travelMode: TRAVEL_MODE,
    routingPreference: "TRAFFIC_UNAWARE",
  };
  const r = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GKEY,
      "X-Goog-FieldMask": "routes.legs.duration,routes.legs.distanceMeters,routes.legs.polyline.encodedPolyline",
    },
    body: JSON.stringify(reqBody),
  });
  const j = await r.json();
  if (!r.ok) throw new Error("google:" + JSON.stringify(j));
  const route = j?.routes?.[0];
  if (!route || !route.legs) return null;
  return route.legs.map((leg) => ({
    min: leg.duration ? parseInt(String(leg.duration).replace("s", "")) / 60 : null,
    dist: leg.distanceMeters ?? null,
    poly: leg.polyline?.encodedPolyline ?? null,
  }));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json();
    const { a, b } = await secrets();
    // سر فاضي = رفض، مش سماح للكل
    if (!a || (body.secret !== a && !(b && body.secret === b))) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }
    const tripId = body.trip_id;
    if (!tripId) return json({ ok: false, error: "no trip_id" }, 400);

    const trip = (await sbGet(`trips?id=eq.${tripId}&select=id,branch_id,status,completed_at,updated_at`))[0];
    if (!trip) return json({ ok: false, error: "trip not found" }, 404);
    const completionTime = trip.completed_at || trip.updated_at;

    const links = await sbGet(`trip_orders?trip_id=eq.${tripId}&select=order_id`);
    const ids = links.map((l) => l.order_id);
    if (!ids.length) return json({ ok: false, error: "no orders in trip" });

    // الطلبات المسلّمة بموقع، بترتيب التسليم الفعلي
    const orders = await sbGet(
      `orders?id=in.(${ids.join(",")})&delivered_at=not.is.null&delivery_lat=not.is.null&order=delivered_at.asc&select=id,delivery_lat,delivery_lng,delivered_at,picked_at`,
    );
    if (!orders.length) return json({ ok: false, error: "no delivered orders with location" });

    const settings = (await sbGet(
      `dispatch_settings?branch_id=eq.${trip.branch_id}&select=pharmacy_lat,pharmacy_lng,handover_minutes,pickup_minutes,driver_excellent_pct,driver_late_pct`,
    ))[0] || {};
    const plat = parseFloat(settings.pharmacy_lat), plng = parseFloat(settings.pharmacy_lng);
    if (!plat || !plng) return json({ ok: false, error: "no pharmacy location" });
    const pharmacy = { lat: plat, lng: plng };
    const handover = Number(settings.handover_minutes) || 0;
    const pickup = Number(settings.pickup_minutes) || 0;
    const exc = (Number(settings.driver_excellent_pct) || 90) / 100;
    const lt = (Number(settings.driver_late_pct) || 110) / 100;
    const rate = (ratio) => (ratio <= exc ? "ممتاز" : ratio >= lt ? "متأخر" : "جيد");

    const stops = orders.map((o) => ({ lat: Number(o.delivery_lat), lng: Number(o.delivery_lng) }));
    const legs = await googleTripRoute(pharmacy, stops); // ← نداء واحد فقط
    if (!legs || legs.length < orders.length + 1) return json({ ok: false, error: "route legs mismatch", got: legs?.length ?? 0 });

    // كل طلب من الـleg الموصّل ليه: leg[0]=صيدلية->طلب0، leg[1]=طلب0->طلب1 ...
    let prevDeliveredAt = null;
    for (let i = 0; i < orders.length; i++) {
      const o = orders[i];
      const leg = legs[i];
      const travelMin = leg?.min ?? null;
      const distMeters = leg?.dist ?? null;
      const isFirst = i === 0;
      const expected = travelMin == null ? null : travelMin + handover + (isFirst ? pickup : 0);
      const startTime = isFirst ? o.picked_at : prevDeliveredAt;
      let actual = null;
      if (startTime) actual = (new Date(o.delivered_at).getTime() - new Date(startTime).getTime()) / 60000;
      let rating = null;
      if (expected && actual != null && expected > 0) rating = rate(actual / expected);
      await sbPatch(`orders?id=eq.${o.id}`, {
        expected_minutes: expected == null ? null : Math.round(expected * 10) / 10,
        actual_minutes: actual == null ? null : Math.round(actual * 10) / 10,
        perf_rating: rating,
        distance_meters: distMeters,
        route_polyline: leg?.poly ?? null,
      });
      prevDeliveredAt = o.delivered_at;
    }

    // العودة = آخر leg (آخر طلب -> الصيدلية)
    const retLeg = legs[orders.length];
    const rExpected = retLeg?.min == null ? null : retLeg.min + handover;
    const lastDelivered = orders[orders.length - 1].delivered_at;
    let rActual = null;
    if (completionTime) rActual = (new Date(completionTime).getTime() - new Date(lastDelivered).getTime()) / 60000;
    let rRating = null;
    if (rExpected && rActual != null && rExpected > 0) rRating = rate(rActual / rExpected);
    await sbPatch(`trips?id=eq.${tripId}`, {
      return_expected_minutes: rExpected == null ? null : Math.round(rExpected * 10) / 10,
      return_actual_minutes: rActual == null ? null : Math.round(rActual * 10) / 10,
      return_distance_meters: retLeg?.dist ?? null,
      return_rating: rRating,
      return_polyline: retLeg?.poly ?? null,
    });

    return json({ ok: true, orders_rated: orders.length, google_calls: 1 });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
