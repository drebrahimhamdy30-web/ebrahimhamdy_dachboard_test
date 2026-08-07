/* ============================================================
 * متابعة أرصدة الموردين — منطق التحليل والمقارنة (نقي، بدون DOM)
 * منقول كما هو منطقيًا من النموذج docs/reference/supplier_balances.html
 * متقسّم في ملف مستقل عشان الصفحة تستخدمه + التست يقدر يستدعيه في Node.
 *
 * الدوال:
 *   norm(s)                          تطبيع النص العربي قبل مطابقة العناوين
 *   toNum(v)                         تحويل نص لرقم (يدعم السالب 1.000- و -1.000 و (1.000) والأرقام العربية)
 *   parse(text)                      قراءة الجدول الملصوق -> { rows, skipped, foundHeader, count } أو { error }
 *   compare(oldSnap, newSnap, cfg)   المقارنة -> { changed, added, removed, total, baseline }
 *                                    cfg = { exclusions:[{code}], threshold:number }
 * ============================================================ */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;      // Node (التست)
  root.SupBalParser = api;                                                       // المتصفح (الصفحة)
})(typeof self !== 'undefined' ? self : this, function () {

  // تطبيع النص العربي: تشكيل/تطويل + أ إ آ->ا، ى->ي، ة->ه، توحيد المسافات
  const norm = s => (s || '')
    .replace(/[ـً-ْ]/g, '')
    .replace(/[أإآ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه')
    .replace(/\s+/g, ' ').trim().toLowerCase();

  function toNum(v) {
    if (v == null) return NaN;
    let s = String(v).replace(/[٫]/g, '.').replace(/[,٬\s‏‎]/g, '').trim();
    s = s.replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d));
    let neg = false;
    if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1); }
    if (s.endsWith('-')) { neg = true; s = s.slice(0, -1); }   // شكل 1.000-
    if (s.startsWith('-')) { neg = true; s = s.slice(1); }
    if (s === '' || isNaN(Number(s))) return NaN;
    return (neg ? -1 : 1) * Number(s);
  }

  // قراءة الجدول الملصوق: يتعرّف على العناوين العربية لو موجودة، وإلا الترتيب الافتراضي.
  // الفصل بالتاب، وإلا بمسافتين أو أكثر. يتخطّى أي سطر مالوش كود صالح أو رصيد رقمي.
  function parse(text) {
    const lines = String(text || '').split(/\r?\n/).filter(l => l.trim() !== '');
    if (!lines.length) return { rows: {}, skipped: 0, error: 'ما فيش بيانات في الصندوق.' };

    const cut = l => l.includes('\t') ? l.split('\t') : l.split(/ {2,}| {2,}/);
    // الترتيب الافتراضي: [المسحوبات الحالية، حد المسحوبات، المدير، التليفون، الاسم EN، الاسم AR، الكود]
    let idx = { bal: 0, limit: 1, mgr: 2, phone: 3, en: 4, ar: 5, code: 6 };
    let start = 0, foundHeader = false;

    for (let i = 0; i < Math.min(lines.length, 5); i++) {
      const cells = cut(lines[i]).map(norm);
      if (!cells.some(c => c.includes('كود'))) continue;
      const m = {};
      cells.forEach((c, j) => {
        if (c.includes('كود')) m.code = j;
        else if (c.includes('حد') && c.includes('مسحوبات')) m.limit = j;
        else if (c.includes('مسحوبات') || c.includes('رصيد')) m.bal = j;
        else if (c.includes('(ع') || c.includes('عربي')) m.ar = j;
        else if (c.includes('(en') || c.includes('انجل')) m.en = j;
        else if (c.includes('تليفون') || c.includes('هاتف') || c.includes('موبايل')) m.phone = j;
        else if (c.includes('مدير')) m.mgr = j;
      });
      if (m.code !== undefined && m.bal !== undefined) { idx = Object.assign(idx, m); start = i + 1; foundHeader = true; break; }
    }

    const rows = {}; let skipped = 0;
    for (let i = start; i < lines.length; i++) {
      const c = cut(lines[i]).map(x => String(x).replace(/‏|‎/g, '').trim());
      const code = c[idx.code];
      const bal = toNum(c[idx.bal]);
      if (!code || !/^[0-9A-Za-z\-]+$/.test(code) || isNaN(bal)) { skipped++; continue; }
      rows[code] = {
        b: bal,
        a: c[idx.ar] || '',
        e: c[idx.en] || '',
        l: toNum(c[idx.limit]),
        p: c[idx.phone] || ''
      };
    }
    const n = Object.keys(rows).length;
    if (!n) return { rows: {}, skipped, error: 'مفيش صف واحد اتقرأ. اتأكد إنك ناسخ الجدول بالأعمدة زي ما هو من الشاشة.' };
    return { rows, skipped, foundHeader, count: n };
  }

  // المقارنة بين المرجع القديم والكشف الجديد. cfg.exclusions أكواد تُستبعد، cfg.threshold حد تجاهل الفروق.
  function compare(oldSnap, newSnap, cfg) {
    cfg = cfg || {};
    const ex = new Set((cfg.exclusions || []).map(x => String(x && x.code != null ? x.code : x)));
    const th = Number(cfg.threshold) || 0;
    const changed = [], added = [], removed = [];

    Object.keys(newSnap).forEach(code => {
      if (ex.has(code)) return;
      const cur = newSnap[code];
      const prev = oldSnap ? oldSnap[code] : undefined;
      if (!prev) { added.push({ code, name: cur.a || cur.e, en: cur.e, phone: cur.p, now: cur.b }); return; }
      const d = cur.b - prev.b;
      if (Math.abs(d) > th) changed.push({ code, name: cur.a || cur.e, en: cur.e, phone: cur.p, before: prev.b, now: cur.b, diff: d });
    });
    if (oldSnap) Object.keys(oldSnap).forEach(code => {
      if (ex.has(code) || newSnap[code]) return;
      removed.push({ code, name: oldSnap[code].a || oldSnap[code].e, en: oldSnap[code].e, before: oldSnap[code].b });
    });

    changed.sort((a, b) => Math.abs(b.diff) - Math.abs(a.diff));
    added.sort((a, b) => String(a.code).localeCompare(String(b.code), 'en', { numeric: true }));
    removed.sort((a, b) => String(a.code).localeCompare(String(b.code), 'en', { numeric: true }));
    return { changed, added, removed, total: Object.keys(newSnap).length, baseline: !!oldSnap };
  }

  return { norm, toNum, parse, compare };
});
