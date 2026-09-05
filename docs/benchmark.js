/* ═══════════════════════════════════════════════════════════════════
   تأكيد الخادم + قياس السرعة
   ═══════════════════════════════════════════════════════════════════
   شغّله على **الموقعين** وقارن:
     · التست  → drebrahimhamdy30-web.github.io/ebrahimhamdy_dachboard_test/
     · الحي   → phalix.ebrahimhamdy.com
   افتح أي شاشة (بعد تسجيل الدخول عشان القياس الثقيل يشتغل)،
   F12 ← Console ← الصق ← Enter.

   بيقيس 3 حاجات:
     1. زمن الشبكة (ping) — رحلة فاضية للخادم
     2. استعلام خفيف (الفروع) — الشبكة + البوابة + PostgREST
     3. استعلام ثقيل (5000 صف مبيعات) — أداء القاعدة الحقيقي
   ═══════════════════════════════════════════════════════════════════ */
(async () => {
  const U = PHALIX_CONFIG.supabaseUrl;
  const K = PHALIX_CONFIG.supabaseAnonKey;
  const out = {};

  out['الخادم'] = U.replace('https://', '');
  out['نوعه'] = U.includes('supabase.co') ? '☁️ سحابة Supabase' : '🖥️ السيرفر الخاص';

  const auth = async () => {
    try { return await Session.headers(); }
    catch (e) { return { apikey: K, Authorization: 'Bearer ' + K }; }
  };
  const H = await auth();
  let role = 'anon';
  try { role = JSON.parse(atob(H.Authorization.split(' ')[1].split('.')[1]
          .replace(/-/g, '+').replace(/_/g, '/'))).role; } catch (e) {}
  out['الدور المستعمل'] = role + (role === 'anon' ? ' ⚠️ سجّل دخول للقياس الثقيل' : ' ✅');

  // مقياس: بيرجّع أقل زمن ووسيط من عدة محاولات (أقل زمن = أقل تشويش)
  const bench = async (label, fn, reps) => {
    const ts = [];
    for (let i = 0; i < reps; i++) {
      const t0 = performance.now();
      try { await fn(); } catch (e) { return { label, err: String(e.message).slice(0, 40) }; }
      ts.push(performance.now() - t0);
    }
    ts.sort((a, b) => a - b);
    return { أقل: Math.round(ts[0]), وسيط: Math.round(ts[Math.floor(ts.length / 2)]),
             أعلى: Math.round(ts[ts.length - 1]) };
  };

  // 1) زمن الشبكة
  out['① الشبكة (ms)'] = await bench('ping',
    () => fetch(U + '/auth/v1/health', { headers: { apikey: K }, cache: 'no-store' }), 7);

  // 2) استعلام خفيف
  out['② استعلام خفيف (ms)'] = await bench('light',
    () => fetch(U + '/rest/v1/branches?select=*&order=sort_order', { headers: H, cache: 'no-store' }), 7);

  // 3) استعلام ثقيل — 5000 صف مبيعات
  if (role !== 'anon') {
    out['③ 5000 صف مبيعات (ms)'] = await bench('heavy',
      () => fetch(U + '/rest/v1/sales_items?select=id,bill_no,net_val&limit=5000', { headers: H, cache: 'no-store' }), 3);

    // 4) دالة تجميع — أقرب حاجة لشغل الشاشات الحقيقي
    out['④ ملخّص المبيعات RPC (ms)'] = await bench('rpc',
      () => fetch(U + '/rest/v1/rpc/sales_summary', { method: 'POST', headers: H,
                   body: '{}', cache: 'no-store' }), 3);
  }

  // حجم البيانات للتأكيد إنها نفس القاعدة
  try {
    const r = await fetch(U + '/rest/v1/orders?select=id&limit=1', { headers: H });
    out['عدد الطلبات (تأكيد نفس البيانات)'] =
      (await fetch(U + '/rest/v1/orders?select=id', { headers: { ...H, Prefer: 'count=exact', Range: '0-0' } }))
        .headers.get('content-range') || '—';
  } catch (e) {}

  console.table(out);
  console.log(JSON.stringify(out, null, 1));
  return out;
})();
