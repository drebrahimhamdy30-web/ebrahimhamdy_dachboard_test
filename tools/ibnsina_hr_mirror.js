/* ═══════════════════════════════════════════════════════════════════
   نسخة لنظام HR من نداءات ابن سينا (فترة الانتقال — قرار المالك 2026-11-26)
   ═══════════════════════════════════════════════════════════════════
   المشتريات اتنقلت لـHR، وبوابة ابن سينا بتحجب سيرفر HR (403) — فالسحب
   بيفضل من الجهاز ده، وأي نداء بيروح للنظام القديم بيروح نسخة منه لـHR
   بنفس الشكل (اسم الدالة + البيانات) على:
     {hrUrl}/api/web/integrations/ibnsina/rpc/{fn}
   بمفتاح HR الخاص (hrSyncKey) بدل مفتاح النظام القديم.

   الإعدادات في ibnsina.local.json (مستثنى من git):
     "hrUrl": "https://hr.ebrahimhamdy.com", "hrSyncKey": "<IBNSINA_SYNC_KEY من .env بتاع HR>"
   لو مش موجودين = مفيش نسخة (السلوك القديم زي ما هو).

   فشل HR **مايوقفش** المزامنة الأساسية — بيطبع تحذير بس، والجولة الجاية
   بتعيد (الكتابة في HR قابلة للإعادة).
   ═══════════════════════════════════════════════════════════════════ */

async function hrMirror(cfg, fn, body) {
  if (!cfg || !cfg.hrUrl || !cfg.hrSyncKey || String(cfg.hrSyncKey).startsWith('<')) return null;
  const url = String(cfg.hrUrl).replace(/\/+$/, '') + '/api/web/integrations/ibnsina/rpc/' + fn;
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({}, body, { p_key: cfg.hrSyncKey })),
      signal: AbortSignal.timeout(120000)
    });
    const t = await r.text();
    if (!r.ok) { console.error(`  ⚠️ HR ${fn} → HTTP ${r.status}: ${t.slice(0, 150)}`); return null; }
    try { return JSON.parse(t); } catch { return t; }
  } catch (e) {
    console.error(`  ⚠️ HR ${fn}: ${e.message}`);
    return null;
  }
}

module.exports = { hrMirror };
