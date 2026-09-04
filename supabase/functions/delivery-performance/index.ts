import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
// وضع المركبة لحساب زمن الطريق (الطيارون دراجات نارية)
const TRAVEL_MODE = "TWO_WHEELER";
const SB_URL = Deno.env.get("SUPABASE_URL");
const SRK = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const GKEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";

// ⚠️ السر مايتكتبش في الكود — من vault. الدالة دي بتنادى من تريجرات
// القاعدة بس (مش من تطبيق السواقين)، فسرها اتغيّر لوحده.
// سر التطبيق القديم مقبول كمان فترة انتقالية — مفيش لحظة انقطاع.
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
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function sbGet(path) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {
    headers: { apikey: SRK, Authorization: `Bearer ${SRK}` },
  });
  if (!r.ok) return [];
  return await r.json();
}

async function sbPatch(path, body) {
  await fetch(`${SB_URL}/rest/v1/${path}`, {
    method: "PATCH",
    headers: {
      apikey: SRK,
      Authorization: `Bearer ${SRK}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(body),
  });
}

async function googleRoute(o, d, mode = TRAVEL_MODE) {
  const reqBody = {
    origin: { location: { latLng: { latitude: o.lat, longitude: o.lng } } },
    destination: { location: { latLng: { latitude: d.lat, longitude: d.lng } } },
    travelMode: mode,
  };
  if (mode === "DRIVE" || mode === "TWO_WHEELER") reqBody.routingPreference = "TRAFFIC_UNAWARE";
  const r = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GKEY,
      "X-Goog-FieldMask": "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline",
    },
    body: JSON.stringify(reqBody),
  });
  const j = await r.json();
  if (!r.ok) throw new Error("google:" + JSON.stringify(j));
  const route = j?.routes?.[0];
  if (!route) return null;
  const dur = route.duration;
  return {
    min: dur ? parseInt(dur.replace("s", "")) / 60 : null,
    dist: route.distanceMeters ?? null,
    poly: route.polyline?.encodedPolyline ?? null,
  };
}

// يجيب نقطة بداية الرِجل: آخر طلب مُسلّم في نفس الرحلة قبل الوقت المرجعي، وإلا الصيدلية
async function legStart(orderId, refTime, settings) {
  let start = null, isFirst = true, prevDeliveredAt = null;
  const link = (await sbGet(`trip_orders?order_id=eq.${orderId}&select=trip_id`))[0];
  if (link) {
    const sibs = await sbGet(`trip_orders?trip_id=eq.${link.trip_id}&select=order_id`);
    const ids = sibs.map((s) => s.order_id).filter((x) => x !== orderId);
    if (ids.length && refTime) {
      const prev = await sbGet(
        `orders?id=in.(${ids.join(",")})&delivered_at=lt.${encodeURIComponent(refTime)}&delivery_lat=not.is.null&order=delivered_at.desc&limit=1&select=delivery_lat,delivery_lng,delivered_at`,
      );
      if (prev.length) {
        start = { lat: Number(prev[0].delivery_lat), lng: Number(prev[0].delivery_lng) };
        isFirst = false;
        prevDeliveredAt = prev[0].delivered_at;
      }
    }
  }
  if (!start) {
    const plat = parseFloat(settings.pharmacy_lat);
    const plng = parseFloat(settings.pharmacy_lng);
    if (!plat || !plng) return null;
    start = { lat: plat, lng: plng };
  }
  return { start, isFirst, prevDeliveredAt };
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

    if (body.test) {
      const g = await googleRoute(body.origin, body.dest, body.mode || TRAVEL_MODE);
      return json({ ok: true, mode: body.mode || TRAVEL_MODE, minutes: g?.min, meters: g?.dist });
    }

    const orderId = body.order_id;
    if (!orderId) return json({ ok: false, error: "no order_id" }, 400);

    const ord = (await sbGet(`orders?id=eq.${orderId}&select=id,delivery_lat,delivery_lng,delivered_at,picked_at,branch_id,fail_lat,fail_lng,updated_at,status`))[0];
    if (!ord) return json({ ok: false, error: "order not found" }, 404);

    const hasDelivery = ord.delivery_lat != null && ord.delivery_lng != null;
    const isFail = !hasDelivery && ord.fail_lat != null && ord.fail_lng != null;

    const settings = (await sbGet(
      `dispatch_settings?branch_id=eq.${ord.branch_id}&select=pharmacy_lat,pharmacy_lng,handover_minutes,pickup_minutes,driver_excellent_pct,driver_late_pct`,
    ))[0] || {};

    // ===== طلب متعذّر: نحسب مسافة الرِجل (آخر مُسلّم → موقع التعذّر) ونخزّنها في fail_distance_meters =====
    if (isFail) {
      const ls = await legStart(orderId, ord.updated_at, settings);
      if (!ls) return json({ ok: false, error: "no pharmacy location" });
      const g = await googleRoute(ls.start, { lat: Number(ord.fail_lat), lng: Number(ord.fail_lng) });
      await sbPatch(`orders?id=eq.${orderId}`, { fail_distance_meters: g?.dist ?? null });
      return json({ ok: true, fail: true, distMeters: g?.dist ?? null, isFirst: ls.isFirst });
    }

    // ===== طلب مُسلّم: الأداء + المسافة (زي ما كان) =====
    if (!hasDelivery) return json({ ok: false, error: "no delivery location" });

    const ls = await legStart(orderId, ord.delivered_at, settings);
    if (!ls) return json({ ok: false, error: "no pharmacy location" });

    const g = await googleRoute(ls.start, { lat: Number(ord.delivery_lat), lng: Number(ord.delivery_lng) });
    const travelMin = g?.min ?? null;
    const distMeters = g?.dist ?? null;
    const handover = Number(settings.handover_minutes) || 0;
    const pickup = Number(settings.pickup_minutes) || 0;
    const expected = travelMin == null ? null : travelMin + handover + (ls.isFirst ? pickup : 0);

    let actual = null;
    if (ord.delivered_at) {
      const startTime = ls.isFirst ? ord.picked_at : ls.prevDeliveredAt;
      if (startTime) actual = (new Date(ord.delivered_at).getTime() - new Date(startTime).getTime()) / 60000;
    }

    let rating = null;
    if (expected && actual != null && expected > 0) {
      const ratio = actual / expected;
      const exc = (Number(settings.driver_excellent_pct) || 90) / 100;
      const lt = (Number(settings.driver_late_pct) || 110) / 100;
      rating = ratio <= exc ? "ممتاز" : ratio >= lt ? "متأخر" : "جيد";
    }

    await sbPatch(`orders?id=eq.${orderId}`, {
      expected_minutes: expected == null ? null : Math.round(expected * 10) / 10,
      actual_minutes: actual == null ? null : Math.round(actual * 10) / 10,
      perf_rating: rating,
      distance_meters: distMeters,
      route_polyline: g?.poly ?? null,
    });

    return json({ ok: true, expected, actual, rating, travelMin, distMeters, isFirst: ls.isFirst });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
