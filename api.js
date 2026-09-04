// الرابط والمفتاح بييجوا من config.js — لازم يتحمّل قبل الملف ده
const FETCH_URL     = "https://agent.ebrahimhamdy.com/webhook/get_order";
const POST_URL      = "https://agent.ebrahimhamdy.com/webhook/taskmanagement";
const LOGIN_URL     = "https://agent.ebrahimhamdy.com/webhook/login";
const VERIFY_URL    = "https://agent.ebrahimhamdy.com/webhook/verify_token";
const DASHBOARD_URL = "https://agent.ebrahimhamdy.com/webhook/dashboard";
const PAYMOB_URL    = "https://agent.ebrahimhamdy.com/webhook/paymobtransaction";

// بحث الصنف من مخزون Supabase مباشرة (بدل نداء ERP) — يرجّع {found,itm_name_ar,itm_name_en,balance,item_type}

// الهوية في brand.js والفروع في branches.js — كانت الكتلة دي مكررة
// حرفيًا في 3 ملفات.
async function sbItemLookup(code, branch) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/item_lookup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'apikey': SB_ANON_API, 'Authorization': 'Bearer ' + SB_ANON_API },
      body: JSON.stringify({ p_code: String(code || ''), p_branch: branch || localStorage.getItem('userBranch') || '' })
    });
    if (!r.ok) return { found: false };
    return await r.json();
  } catch (e) { return { found: false }; }
}

// ===================== جدول task على Supabase (بدل n8n) =====================
// نكتب/نقرأ/نحدّث الطلبات والتحويلات مباشرة على جدول task في Supabase عبر PostgREST
// بمفتاح anon (نفس أسلوب صفحات الصيدلية). السكوب على الفرع بيتعمل في الصفحة زي ما هو دلوقتي.
const SB_TASK_URL     = `${SB_URL_API}/rest/v1/task`;
// ترويسة النداء: توكن المستخدم لو صالح (Session بيجدّده لو لزم)، وإلا مفتاح
// anon. الجداول المالية (contracts / sales_items / …) بتتقفل على anon، يعني
// النداء لازم يبقى authenticated وإلا يرجّع صفوف فاضية أو 401.
// ⚠️ لازم تتنادى **لكل نداء**: كائن ثابت بيتبني وقت التحميل بيقدم بعد ساعة
//    ويخلّي كل حاجة ترجّع 401 من غير سبب واضح.
async function sbH(extra) {
  const h = (typeof Session !== 'undefined' && Session.headers)
    ? await Session.headers()
    : { 'Content-Type': 'application/json', apikey: SB_ANON_API, Authorization: 'Bearer ' + SB_ANON_API };
  return extra ? { ...h, ...extra } : h;
}

const SB_TASK_HEADERS = {
  'Content-Type':  'application/json',
  'apikey':        SB_ANON_API,
  'Authorization': 'Bearer ' + SB_ANON_API
};

// إدراج طلب/تحويل جديد — بيرجّع { ok, data } (نفس شكل updateDataWithResponse)
// بيحوّل حقول الفورم لأعمدة الجدول (نفس ماب n8n القديم، مع تصحيح الفرع:
// للتحويل = الفرع المستهدف، وللشراء = فرع صاحب الطلب نفسه بدل ما يفضل فاضي)
async function sbTaskInsert(payload) {
  try {
    const isTransfer = (payload.type === 'تحويل');
    const isNotif    = (payload.type === 'إشعار');
    // الفرع: للتحويل = المستهدف، وللشراء/الإشعار = فرع صاحب الطلب (المُرسِل)
    const branchVal  = isTransfer
      ? (payload.target_branch || '')
      : (payload.branch || payload.user || '');
    const row = {
      "user":        payload.user || null,
      type:          payload.type || null,
      branch:        branchVal || null,
      qty:           (payload.qty != null ? String(payload.qty) : null),
      cust_code:     payload.customer_code || null,
      cust_name:     payload.customer_name || null,
      item_name:     payload.item || payload.item_name_ar || payload.item_name || null,
      item_code:     payload.item_code || null,
      order_type:    payload.order_type || null,
      note:          payload.note || null,
      state:         payload.state || 'pending',
      // حقول الإشعارات (بتفضل فاضية في الشراء/التحويل)
      target_branch: isNotif ? (payload.target_branch || null) : null,
      target_type:   payload.target_type || null,
      assigned_to:   payload.assigned_to || null,
      done:          null,
      comment:       null
    };
    const r = await fetch(SB_TASK_URL, {
      method:  'POST',
      headers: await sbH({ 'Prefer': 'return=representation' }),
      body:    JSON.stringify(row)
    });
    if (!r.ok) return { ok: false, data: null };
    let data = null;
    try { const raw = await r.json(); data = Array.isArray(raw) ? (raw[0] || null) : raw; } catch (e) {}
    return { ok: true, data };
  } catch (e) {
    console.error('sbTaskInsert error:', e);
    return { ok: false, data: null };
  }
}

// جلب صفوف task — بيرجّع Array من objects (نفس شكل fetchOrders)
// opts.type لفلترة النوع (شراء/تحويل...). بنرجّع createdAt (camelCase) عشان الصفحات القديمة.
async function sbTaskList(opts = {}) {
  try {
    const params = new URLSearchParams();
    params.set('select', opts.select || '*');
    params.set('order', 'created_at.desc');
    if (opts.type)   params.set('type',  `eq.${opts.type}`);
    if (opts.user)   params.set('user',  `eq.${opts.user}`);
    if (opts.states && opts.states.length) params.set('state', `in.(${opts.states.join(',')})`);
    if (opts.limit)  params.set('limit', String(opts.limit));
    const r = await fetch(`${SB_TASK_URL}?${params.toString()}`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    if (!Array.isArray(rows)) return [];
    return rows.map(x => ({ ...x, createdAt: x.created_at }));
  } catch (e) {
    console.error('sbTaskList error:', e);
    return [];
  }
}

// تحديث صف task عبر id — patch عبارة عن أعمدة الجدول (state/company/item_name/...) — بيرجّع true/false
async function sbTaskUpdate(id, patch) {
  try {
    const clean = {};
    Object.keys(patch || {}).forEach(k => { if (patch[k] !== undefined) clean[k] = patch[k]; });
    const r = await fetch(`${SB_TASK_URL}?id=eq.${encodeURIComponent(id)}`, {
      method:  'PATCH',
      headers: await sbH(),
      body:    JSON.stringify(clean)
    });
    return r.ok;
  } catch (e) {
    console.error('sbTaskUpdate error:', e);
    return false;
  }
}

// ===================== التعاقدات + عدم الوصول على Supabase (بدل n8n) =====================
const SB_CONTRACT_URL = `${SB_URL_API}/rest/v1/contracts`;
const SB_MISSING_URL  = `${SB_URL_API}/rest/v1/missing_items`;

// إدراج فاتورة تعاقد — بيفحص الحظر الأول (لو العميل عنده أي صف status='block')
// بيرجّع { ok, blocked }
async function sbContractInsert({ branch, cust_code, total_amount, notes, customer_code, customer_name }) {
  try {
    const chk = await fetch(
      `${SB_CONTRACT_URL}?select=id&cust_code=eq.${encodeURIComponent(cust_code || '')}&status=eq.block&limit=1`,
      { headers: await sbH() }
    );
    if (chk.ok) {
      const rows = await chk.json();
      if (Array.isArray(rows) && rows.length) return { ok: false, blocked: true };
    }
    const r = await fetch(SB_CONTRACT_URL, {
      method: 'POST',
      headers: await sbH({ 'Prefer': 'return=minimal' }),
      body: JSON.stringify({
        branch:       branch || null,
        cust_code:    cust_code || null,
        customer_code: customer_code || null,
        customer_name: customer_name || null,
        total_amount: (total_amount != null ? String(total_amount) : null),
        notes:        notes || null,
        status:       'unpaid'
      })
    });
    return { ok: r.ok, blocked: false };
  } catch (e) { console.error('sbContractInsert error:', e); return { ok: false, blocked: false }; }
}

async function sbContractUpdate(id, patch) {
  try {
    const r = await fetch(`${SB_CONTRACT_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'PATCH', headers: await sbH(), body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbContractUpdate error:', e); return false; }
}

async function sbContractList() {
  try {
    const r = await fetch(`${SB_CONTRACT_URL}?select=*&order=created_at.desc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows.map(x => ({ ...x, createdAt: x.created_at })) : [];
  } catch (e) { console.error('sbContractList error:', e); return []; }
}

// إدراج بلاغ عدم وصول
async function sbMissingInsert({ branch, invoice_no, item_name, qty, supplier_code }) {
  try {
    const r = await fetch(SB_MISSING_URL, {
      method: 'POST',
      headers: await sbH({ 'Prefer': 'return=minimal' }),
      body: JSON.stringify({
        branch:        branch || null,
        invoice_no:    invoice_no || null,
        item_name:     item_name || null,
        qty:           (qty != null ? String(qty) : null),
        supplier_code: supplier_code || null,
        state:         false,
        call:          false
      })
    });
    return r.ok;
  } catch (e) { console.error('sbMissingInsert error:', e); return false; }
}

async function sbMissingUpdate(id, patch) {
  try {
    const r = await fetch(`${SB_MISSING_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'PATCH', headers: await sbH(), body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbMissingUpdate error:', e); return false; }
}

async function sbMissingList() {
  try {
    const r = await fetch(`${SB_MISSING_URL}?select=*&order=created_at.desc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows.map(x => ({ ...x, createdAt: x.created_at })) : [];
  } catch (e) { console.error('sbMissingList error:', e); return []; }
}

// ---- متابعة النواقص: طلبات "غير متوفر يحتاج متابعة" + رصيد المخزون الحالي (stq) لحظيًا ----
// بيرجّع Array فيه {id,item_name,item_code,user,branch,cust_name,cust_code,cust_state,createdAt,stq}
async function sbShortages(branch) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/get_shortages`, {
      method: 'POST',
      headers: await sbH(),
      body: JSON.stringify({ p_branch: branch || 'عام' })
    });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbShortages error:', e); return []; }
}

// ===================== تقارير المبيعات (RPCs على sales_items) =====================
async function _sbRpc(fn, body) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: await sbH(), body: JSON.stringify(body || {})
    });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error(fn + ' error:', e); return []; }
}
function sbSalesSummary(from, to, store)      { return _sbRpc('sales_summary',     { p_from: from||null, p_to: to||null, p_store: store||null }); }
function sbSalesTopItems(from, to, store, lim){ return _sbRpc('sales_top_items',   { p_from: from||null, p_to: to||null, p_store: store||null, p_limit: lim||50 }); }
function sbSalesByEmployee(from, to, store)   { return _sbRpc('sales_by_employee', { p_from: from||null, p_to: to||null, p_store: store||null }); }
function sbSalesDetail(opts)                  { const o=opts||{}; return _sbRpc('sales_detail', { p_from:o.from||null, p_to:o.to||null, p_store:o.store||null, p_employee:o.employee||null, p_search:o.search||null, p_limit:o.limit||100, p_offset:o.offset||0 }); }
// تحليل المبيعات — نظرة عامة + ساعات الذروة
async function sbSalesOverview(from, to, store){ const r = await _sbRpc('sales_overview', { p_from: from||null, p_to: to||null, p_store: store||null }); return r[0] || {}; }
// عدد أيام المبيعات الفعلية + آخر يوم مبيعات في الفترة (للمعدل اليومي الدقيق)
async function sbSalesActiveDays(from, to, store){ const r = await _sbRpc('sales_active_days', { p_from: from||null, p_to: to||null, p_store: store||null }); return r[0] || { active_days:0, last_day:null }; }
function sbSalesByHour(from, to, store)        { return _sbRpc('sales_by_hour', { p_from: from||null, p_to: to||null, p_store: store||null }); }
// طلبات التوصيل لكل ساعة + أيام التوصيل الفعلية (لجدول الطيارين المطلوبين)
function sbDeliveryByHour(from, to, store)     { return _sbRpc('delivery_by_hour', { p_from: from||null, p_to: to||null, p_store: store||null }); }
async function sbDeliveryActiveDays(from, to, store){ const r = await _sbRpc('delivery_active_days', { p_from: from||null, p_to: to||null, p_store: store||null }); return r[0] || { active_days:0, last_day:null }; }
// تحليل المبيعات — مراجعة الأسعار والخصومات
function sbSalesPriceReview(from, to, store)  { return _sbRpc('sales_price_review',  { p_from: from||null, p_to: to||null, p_store: store||null }); }
function sbSalesDiscountBills(from, to, store){ return _sbRpc('sales_discount_bills', { p_from: from||null, p_to: to||null, p_store: store||null }); }
// تجميعات الخصومات (لكل موظف/عميل + الإجمالي) — تشمل كل الخصومات في المدة (مش المراجَع فقط)
function sbSalesDiscountStats(from, to, store){ return _sbRpc('sales_discount_stats', { p_from: from||null, p_to: to||null, p_store: store||null }); }
const SB_SALES_URL = `${SB_URL_API}/rest/v1/sales_items`;
const SB_DISCREV_URL = `${SB_URL_API}/rest/v1/sales_discount_reviews`;
async function sbMarkPriceReviewed(id, by) {
  try {
    const r = await fetch(`${SB_SALES_URL}?id=eq.${encodeURIComponent(id)}`, {
      method:'PATCH', headers: await sbH(),
      body: JSON.stringify({ price_reviewed:true, price_reviewed_at:new Date().toISOString(), price_reviewed_by: by||null })
    });
    return r.ok;
  } catch(e){ console.error('sbMarkPriceReviewed', e); return false; }
}
async function sbBillItems(store, billNo) {
  try {
    const url = `${SB_SALES_URL}?store_name=eq.${encodeURIComponent(store)}&bill_no=eq.${encodeURIComponent(billNo)}`
      + `&select=line_no,itm_code,itm_name_ar,unit_name,unit_price,itm_qty,line_total,itm_disc_value,itm_disc_perc,bill_notes&order=line_no.asc`;
    const r = await fetch(url, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbBillItems', e); return []; }
}
async function sbMarkDiscountReviewed(store, billNo, by) {
  try {
    const r = await fetch(SB_DISCREV_URL, {
      method:'POST', headers: await sbH({ 'Prefer':'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify({ store_name:store, bill_no:String(billNo), reviewed_by: by||null, reviewed_at:new Date().toISOString() })
    });
    return r.ok;
  } catch(e){ console.error('sbMarkDiscountReviewed', e); return false; }
}

// ===================== صلاحيات شاشة تحليل المبيعات لكل فرع =====================
const SB_SALES_ACCESS_URL = `${SB_URL_API}/rest/v1/sales_analysis_access`;
// قائمة الفروع المسموح لها بفتح الشاشة — بترجّع Array من store_name
async function sbSalesAccessList() {
  try {
    const r = await fetch(`${SB_SALES_ACCESS_URL}?select=store_name,enabled_at&order=store_name.asc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch(e){ console.error('sbSalesAccessList', e); return []; }
}
// فتح الشاشة لفرع (upsert على store_name)
async function sbSalesAccessEnable(store) {
  try {
    const r = await fetch(SB_SALES_ACCESS_URL, {
      method:'POST', headers: await sbH({ 'Prefer':'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify({ store_name: store })
    });
    return r.ok;
  } catch(e){ console.error('sbSalesAccessEnable', e); return false; }
}
// إغلاق الشاشة لفرع
async function sbSalesAccessDisable(store) {
  try {
    const r = await fetch(`${SB_SALES_ACCESS_URL}?store_name=eq.${encodeURIComponent(store)}`, {
      method:'DELETE', headers: await sbH({ 'Prefer':'return=minimal' })
    });
    return r.ok;
  } catch(e){ console.error('sbSalesAccessDisable', e); return false; }
}

// طلبات خدمة العملاء لفرع — pendingOnly=true يرجّع بس اللي لسه محتاج إجراء (أسرع بكتير)
async function sbCsOrders(branch, pendingOnly) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/get_cs_orders`, {
      method: 'POST',
      headers: await sbH(),
      body: JSON.stringify({ p_branch: branch || '', p_pending: pendingOnly !== false })
    });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbCsOrders error:', e); return []; }
}

// ===================== أسعار الزيوت والخامات (material_prices) =====================
const SB_MATERIAL_URL = `${SB_URL_API}/rest/v1/material_prices`;

async function sbMaterialList() {
  try {
    const r = await fetch(`${SB_MATERIAL_URL}?select=*&order=name.asc,size.asc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbMaterialList error:', e); return []; }
}

async function sbMaterialInsert({ name, size, price }) {
  try {
    const r = await fetch(SB_MATERIAL_URL, {
      method: 'POST',
      headers: await sbH({ 'Prefer': 'return=minimal' }),
      body: JSON.stringify({
        name:  name  || null,
        size:  size  || null,
        price: (price != null && price !== '') ? Number(price) : null
      })
    });
    return r.ok;
  } catch (e) { console.error('sbMaterialInsert error:', e); return false; }
}

async function sbMaterialUpdate(id, patch) {
  try {
    const r = await fetch(`${SB_MATERIAL_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'PATCH', headers: await sbH(), body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbMaterialUpdate error:', e); return false; }
}

async function sbMaterialDelete(id) {
  try {
    const r = await fetch(`${SB_MATERIAL_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'DELETE', headers: await sbH()
    });
    return r.ok;
  } catch (e) { console.error('sbMaterialDelete error:', e); return false; }
}

// ===================== العروض على Supabase (بدل n8n) =====================
const SB_OFFERS_URL = `${SB_URL_API}/rest/v1/offers`;
async function sbOffersList() {
  try {
    const r = await fetch(`${SB_OFFERS_URL}?select=*&order=created_at.desc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbOffersList error:', e); return []; }
}
async function sbOfferInsert({ name, type, details, expires_at, branch }) {
  try {
    const r = await fetch(SB_OFFERS_URL, {
      method: 'POST', headers: await sbH({ 'Prefer': 'return=minimal' }),
      body: JSON.stringify({
        name: name || null, type: type || null, details: details || null,
        expires_at: (expires_at && expires_at !== 'null' && expires_at !== '') ? expires_at : null,
        branch: branch || null
      })
    });
    return r.ok;
  } catch (e) { console.error('sbOfferInsert error:', e); return false; }
}
async function sbOfferUpdate(id, patch) {
  try {
    const r = await fetch(`${SB_OFFERS_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'PATCH', headers: await sbH(), body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbOfferUpdate error:', e); return false; }
}
async function sbOfferDelete(id) {
  try {
    const r = await fetch(`${SB_OFFERS_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'DELETE', headers: await sbH()
    });
    return r.ok;
  } catch (e) { console.error('sbOfferDelete error:', e); return false; }
}

// ===================== الحد الأدنى للمخزون على Supabase (بدل n8n) =====================
// القراءة عبر RPC ترجّع الرصيد الحالي محسوباً لحظياً من مخزون كل فرع
const SB_STOCKLIMIT_URL = `${SB_URL_API}/rest/v1/stock_limit`;
async function sbStockLimits(branch) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/get_stock_limits`, {
      method: 'POST', headers: await sbH(),
      body: JSON.stringify({ p_branch: branch || 'عام' })
    });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbStockLimits error:', e); return []; }
}
// رصيد صنف واحد لحظياً من مخزون فرعه (بدل ويبهوك get_balance)
async function sbItemBalance(code, branch) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/item_balance`, {
      method: 'POST', headers: await sbH(),
      body: JSON.stringify({ p_code: String(code || ''), p_branch: branch || '' })
    });
    if (!r.ok) return 0;
    const v = await r.json();
    return Number(v) || 0;
  } catch (e) { console.error('sbItemBalance error:', e); return 0; }
}
async function sbStockLimitInsert({ item_code, item_name, item_type, branch, min_stock }) {
  try {
    const r = await fetch(SB_STOCKLIMIT_URL, {
      method: 'POST', headers: await sbH({ 'Prefer': 'return=minimal' }),
      body: JSON.stringify({
        item_code: item_code || null, item_name: item_name || null,
        item_type: item_type || null, branch: branch || null,
        min_stock: (min_stock != null && min_stock !== '') ? Number(min_stock) : null
      })
    });
    return r.ok;
  } catch (e) { console.error('sbStockLimitInsert error:', e); return false; }
}
async function sbStockLimitUpdate(id, patch) {
  try {
    const r = await fetch(`${SB_STOCKLIMIT_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'PATCH', headers: await sbH(), body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbStockLimitUpdate error:', e); return false; }
}
async function sbStockLimitDelete(id) {
  try {
    const r = await fetch(`${SB_STOCKLIMIT_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'DELETE', headers: await sbH()
    });
    return r.ok;
  } catch (e) { console.error('sbStockLimitDelete error:', e); return false; }
}

async function fetchFromN8N(category) {
  try {
    const response = await fetch(`${FETCH_URL}?type=${category}`);
    if (!response.ok) throw new Error('Network error');
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    if (Array.isArray(data) && data[0]?.data)         return data[0].data;
    if (Array.isArray(data) && data[0]?.branch)       return data;
    if (Array.isArray(data) && data[0]?.invoice_no)   return data;
    if (Array.isArray(data) && data[0]?.cust_code)    return data;
    if (Array.isArray(data) && data[0]?.bill_no)      return data;
    if (Array.isArray(data) && data[0]?.machine_name) return data;
    if (data.data && Array.isArray(data.data))         return data.data;
    return Array.isArray(data) ? data : [];
  } catch (error) {
    console.error(`Error fetching ${category}:`, error);
    return [];
  }
}

async function fetchFromDashboard(type) {
  try {
    const response = await fetch(`${DASHBOARD_URL}?type=${type}`);
    if (!response.ok) throw new Error('Network error');
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    if (Array.isArray(data) && data[0]?.data) return data[0].data;
    if (data.data && Array.isArray(data.data)) return data.data;
    return Array.isArray(data) ? data : [];
  } catch (error) {
    console.error(`Dashboard fetch error (${type}):`, error);
    return [];
  }
}

// جلب بيانات العملاء من dashboard webhook
async function fetchCustomers() {
  return await fetchFromDashboard('customers');
}

// تعديل بيانات عميل (type / note / category) عبر dashboard webhook
// الحفظ بـ GET query params عشان الـ Switch يقراه من $json.query.type
async function updateCustomer({ cust_code, cust_type, note, category }) {
  try {
    const params = new URLSearchParams({
      type:      'customer_update',
      cust_code: cust_code  || '',
      cust_type: cust_type  || '',
      note:      note       || '',
      category:  category   || ''
    });
    const response = await fetch(`${DASHBOARD_URL}?${params.toString()}`);
    return response.ok;
  } catch (e) {
    console.error('updateCustomer error:', e);
    return false;
  }
}

async function fetchOrders()           { return await fetchFromN8N('orders'); }
async function fetchData()             { return await fetchFromN8N('orders'); }
async function fetchContracts()        { return await sbContractList(); }   // Supabase (بدل n8n)
async function fetchMissing()          { return await sbMissingList(); }    // Supabase (بدل n8n)
async function fetchInventory()        { return await fetchFromN8N('inventory'); }
async function fetchOffers()           { return await fetchFromN8N('offers'); }

// جلب معاملات باي موب عبر webhook paymobtransaction (نوع paymob_get)
async function fetchPaymob() {
  try {
    const response = await fetch(PAYMOB_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: 'paymob_get' })
    });
    if (!response.ok) return [];
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    if (Array.isArray(data) && data[0]?.data) return data[0].data;
    if (data.data && Array.isArray(data.data)) return data.data;
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchPaymob error:', e);
    return [];
  }
}

// إرسال أمر كتابة لـ webhook باي موب (paymobtransaction) — مش taskmanagement
async function postPaymob(data) {
  try {
    const response = await fetch(PAYMOB_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
    return response.ok;
  } catch (e) {
    console.error('postPaymob error:', e);
    return false;
  }
}

// كتابة رقم الفاتورة على معاملة باي موب (ربط) — نوع paymob_update
async function paymobUpdate({ id, bill_no }) {
  return await postPaymob({ type: 'paymob_update', id, bill_no });
}

// إضافة معاملة باي موب يدوي — نوع paymob_insert
async function paymobInsert({ amount, terminal_id, bill_no, transaction_time }) {
  return await postPaymob({
    type: 'paymob_insert',
    amount, terminal_id, bill_no, transaction_time
  });
}

// تعليم كل معاملات يوم معين كـ "تم التحويل" (paid) — نوع paymob_mark_paid
// dayStr بصيغة YYYY-MM-DD
async function paymobMarkPaidForDay(dayStr) {
  return await postPaymob({
    type:      'paymob_mark_paid',
    day_start: dayStr + 'T00:00:00',
    day_end:   dayStr + 'T23:59:59',
    paid:      true
  });
}

// ===================== المصادقة =====================
// فك payload بتاع JWT بترميز UTF-8 صحيح.
// ⚠️ atob لوحده بيخرّب العربي (اسم الفرع بيرجع رموز) — لازم الخطوة الزيادة دي.
// فكّ التوكن — التنفيذ في session.js
const sbDecodeJwt = Session.decodeJwt;

// دخول عبر Supabase Auth. بيرجّع نفس شكل رد n8n عشان الصفحات ماتتغيّرش،
// وبيرجّع null لو فشل لأي سبب → المنادي بيرجع لـn8n.
async function sbAuthLogin(username, password) {
  try {
    const er = await fetch(`${SB_URL_API}/rest/v1/rpc/resolve_login_email`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: SB_ANON_API, Authorization: 'Bearer ' + SB_ANON_API },
      body: JSON.stringify({ p_login: username })
    });
    if (!er.ok) return null;
    const email = await er.json();
    if (!email) return null;

    const tr = await fetch(`${SB_URL_API}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: SB_ANON_API },
      body: JSON.stringify({ email: email, password: password })
    });
    const data = await tr.json();
    if (!tr.ok || !data.access_token) return null;

    const m = (sbDecodeJwt(data.access_token) || {}).app_metadata || {};
    // authProvider و sbRefresh بيتكتبوا مع باقي الجلسة في Session.save()
    return {
      success: true, status: 'success',
      user:      m.username || username,
      role:      m.user_role || 'employee',
      branch:    m.branch || '',
      full_name: m.full_name || m.username || username,
      legacy_id: m.legacy_id || '',
      id:        m.branch_user_id || '',
      token:     data.access_token,
      jwt:       data.access_token,
      provider:  'supabase',
      refresh:   data.refresh_token || ''
    };
  } catch (e) { return null; }
}

async function login(username, password) {
  // Supabase Auth أولًا؛ ولو فشل لأي سبب نرجع لـn8n — فمفيش لحظة قفل أثناء الانتقال
  const sb = await sbAuthLogin(username, password);
  if (sb) return sb;
  try {
    localStorage.removeItem('authProvider');
    localStorage.removeItem('sbRefresh');
    const response = await fetch(LOGIN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify({ user: username, pass: password })
    });
    if (!response.ok) return { success: false, message: "السيرفر لا يستجيب" };
    return await response.json();
  } catch(e) {
    return { success: false, message: "فشل الاتصال بالإنترنت أو السيرفر" };
  }
}

async function updateData(data) {
  try {
    const response = await fetch(POST_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
    return response.ok;
  } catch(e) {
    return false;
  }
}

// زي updateData بالظبط، لكن بترجع الرد الفعلي اللي راجع من الوركفلو (مش true/false بس)
// عشان الصفحة تقدر تعرض البيانات "زي ما اتخزنت فعلاً" بدل رسالة عامة، وتكشف أي حقل ناقص.
// ملحوظة: دي دالة جديدة منفصلة عمداً — updateData() الأصلية فيها استخدامات كتير في صفحات
// تانية بتتعامل معاها كـ true/false بس، فمش هينفع نغيّر شكل الرجوع بتاعها من غير ما نكسرهم.
async function updateDataWithResponse(data) {
  try {
    const response = await fetch(POST_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
    let row = null;
    try {
      const raw = await response.json();
      row = Array.isArray(raw) ? (raw[0] || null) : raw;
    } catch (e) { /* الرد ممكن يكون فاضي أو مش JSON */ }
    return { ok: response.ok, data: row };
  } catch (e) {
    return { ok: false, data: null };
  }
}

// تجديد جلسة Supabase — التنفيذ في session.js (مقفول). الغلاف باقي
// عشان verifyToken() القديمة تفضل شغّالة.
async function sbAuthRefresh() {
  return Session.refresh();
}

async function verifyToken() {
  const token = localStorage.getItem('authToken');
  if (!token) return false;

  // جلسة Supabase: بنتحقق منها محليًا وبنجددها عند اللزوم.
  // ⚠️ من غير الفرع ده، توكن Supabase كان هيتبعت لـwebhook التحقق بتاع n8n
  // اللي مش هيعرفه → «غير صالح» → localStorage.clear() وخروج كل المستخدمين بعد 30 دقيقة.
  if (localStorage.getItem('authProvider') === 'supabase') {
    const p = sbDecodeJwt(localStorage.getItem('authJwt') || '');
    if (p && p.exp && p.exp * 1000 > Date.now() + 60000) return true;
    return await sbAuthRefresh();
  }

  try {
    const response = await fetch(VERIFY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token })
    });
    if (!response.ok) return true;
    const raw  = await response.json();
    const data = Array.isArray(raw) ? (raw[0] || {}) : raw;
    if (data.valid === true)  return true;
    if (data.valid === false) return false;
    if (data.user) return true;
    return false;
  } catch(e) {
    return true;
  }
}

// خروج إجباري لكل الجلسات: بيقارن وقت دخول المستخدم بقيمة force_logout_before على Supabase
async function sbForcedLogoutCheck() {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/app_control?id=eq.1&select=force_logout_before`, { headers: await sbH() });
    if (!r.ok) return false;
    const rows = await r.json();
    const cutoff = (rows && rows[0] && rows[0].force_logout_before) ? new Date(rows[0].force_logout_before).getTime() : 0;
    const loginTime = parseInt(localStorage.getItem('loginTime') || '0', 10);
    if (cutoff && loginTime && loginTime < cutoff) {
      Session.clear();
      window.location.replace('index.html');
      return true;
    }
    return false;
  } catch (e) { return false; }
}

async function checkAuth() {
  const user      = localStorage.getItem('activeUser');
  const token     = localStorage.getItem('authToken');
  const lastCheck = localStorage.getItem('lastVerify');
  const now       = Date.now();
  if (!user || !token) {
    window.location.replace('index.html');
    return null;
  }
  if (await sbForcedLogoutCheck()) return null;
  if (!window.__flTimer) { window.__flTimer = setInterval(sbForcedLogoutCheck, 120000); }
  const thirtyMinutes = 30 * 60 * 1000;
  if (lastCheck && (now - parseInt(lastCheck)) < thirtyMinutes) {
    return user;
  }
  const valid = await verifyToken();
  if (!valid) {
    Session.clear();
    window.location.replace('index.html');
    return null;
  }
  localStorage.setItem('lastVerify', now);
  return user;
}
// ===================== المحافظ (SMS) =====================
// جلب معاملات المحافظ من webhook bmonline (نوع sms)
async function fetchSms() {
  try {
    const response = await fetch(`https://agent.ebrahimhamdy.com/webhook/bmonline?type=sms`);
    if (!response.ok) throw new Error('Network error');
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    if (Array.isArray(data) && data[0]?.data) return data[0].data;
    if (Array.isArray(data) && data[0]?.to_no) return data;
    if (data.data && Array.isArray(data.data)) return data.data;
    return Array.isArray(data) ? data : [];
  } catch (error) {
    console.error('fetchSms error:', error);
    return [];
  }
}

// إضافة معاملة محفظة جديدة — نوع sms_insert
// ملاحظة: محتاج تضيف فرع sms_insert في n8n يقرأ من الـ body
async function insertSms(data) {
  try {
    const response = await fetch(`https://agent.ebrahimhamdy.com/webhook/bmonline`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: 'sms_insert', ...data })
    });
    return response.ok;
  } catch (e) {
    console.error('insertSms error:', e);
    return false;
  }
}
// ===================== إغلاق نقطة البيع + التسوية =====================
// ألصق الدوال دي في آخر api.js عندك (قبل دالة logout أو بعدها، مش فارقة)

// ---- فواتير السيستم (B Connect) ----
// بتمشي على نفس fetchFromN8N بنوع branch_visa_sales
// محتاج تضيف فرع type=branch_visa_sales في n8n يرجّع جدول الفواتير
async function fetchBranchSales() { return await fetchFromN8N('branch_visa_sales'); }

// ---- إغلاق الشيفت ----
// حفظ إغلاق شيفت — بيتبعت لـ taskmanagement (POST_URL) بنوع shift_close
// محتاج تضيف فرع type=shift_close في n8n يخزّن في جدول shift_closes
// وكمان ياخد closed_wallet_ids ويعلّم المعاملات دي كـ "مرحّلة" عشان متظهرش في الشيفت الجديد
async function postShiftClose(data) {
  try {
    const response = await fetch('https://agent.ebrahimhamdy.com/webhook/posupdate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        table: 'shift_closes',
        action: 'insert',
        data: {
          ...data,
          cash_breakdown: typeof data.cash_breakdown === 'object'
            ? JSON.stringify(data.cash_breakdown)
            : data.cash_breakdown
        }
      })
    });
    const text = await response.text();
    const json = text ? JSON.parse(text) : {};
    const d = Array.isArray(json) ? json[0] : json;
    return !!(d && d.ok);
  } catch (e) {
    console.error('postShiftClose error:', e);
    return false;
  }
}

// ===================== نظام الجرد الجديد (Supabase) =====================
const JARD_URL = "https://agent.ebrahimhamdy.com/webhook/inventory_audit_erp";

async function fetchInventoryAudit() {
  try {
    const response = await fetch(JARD_URL);
    if (!response.ok) throw new Error('Network error');
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchInventoryAudit error:', e);
    return [];
  }
}

async function updateInventoryAudit(payload) {
  try {
    const response = await fetch(JARD_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    return response.ok;
  } catch (e) {
    console.error('updateInventoryAudit error:', e);
    return false;
  }
}

// ---- إعدادات فئات الجرد (تلاجه/غوالى) وأكواد fastmove ----
const JARD_SETTINGS_URL = "https://agent.ebrahimhamdy.com/webhook/jard_settings_manage";

async function jardSettingsAction(payload) {
  try {
    const response = await fetch(JARD_SETTINGS_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    if (!response.ok) return null;
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : [data];
  } catch (e) {
    console.error('jardSettingsAction error:', e);
    return null;
  }
}

async function getJardSettings() {
  const res = await jardSettingsAction({ action: 'get_settings' });
  return res || [];
}

async function updateJardSettings(data) {
  const res = await jardSettingsAction({ action: 'update_settings', ...data });
  return res !== null;
}

async function getFastmoveCodes() {
  const res = await jardSettingsAction({ action: 'get_fastmove' });
  return res || [];
}

async function addFastmoveCode(code) {
  const res = await jardSettingsAction({ action: 'add_fastmove', code });
  return res !== null;
}

async function deleteFastmoveCode(id) {
  const res = await jardSettingsAction({ action: 'delete_fastmove', id });
  return res !== null;
}

// ---- أصناف الجرد الحية (فرع + فئة) — لصفحة الجرد الجديدة ----
const JARD_ITEMS_URL = "https://agent.ebrahimhamdy.com/webhook/jard_items";
async function fetchJardItems(branch, category) {
  try {
    const params = new URLSearchParams({ branch, category });
    const response = await fetch(`${JARD_ITEMS_URL}?${params.toString()}`);
    if (!response.ok) return [];
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchJardItems error:', e);
    return [];
  }
}

// ---- تسجيل نتيجة جرد صنف — لصفحة الجرد الجديدة ----
const JARD_AUDIT_LOG_URL = "https://agent.ebrahimhamdy.com/webhook/jard_audit_log";
async function submitJardAudit(payload) {
  try {
    const response = await fetch(JARD_AUDIT_LOG_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    return response.ok;
  } catch (e) {
    console.error('submitJardAudit error:', e);
    return false;
  }
}

// جلب سجل الإغلاقات السابقة — بنفس fetchFromN8N بنوع shift_closes
async function fetchShiftCloses() { return await fetchFromN8N('shift_closes'); }

// ---- تقرير الأصناف اللي لم تُجرد خلال مدة معينة ----
const JARD_STALE_REPORT_URL = "https://agent.ebrahimhamdy.com/webhook/jard_stale_report";
async function fetchStaleItems(branch, months) {
  try {
    const params = new URLSearchParams({ branch, months: months || 3 });
    const response = await fetch(`${JARD_STALE_REPORT_URL}?${params.toString()}`);
    if (!response.ok) return [];
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchStaleItems error:', e);
    return [];
  }
}

// ---- معدل الجرد اليومي لكل موظف (يدعم نطاق تاريخ من - إلى) ----
// معدل الجرد اليومي — يُحسب مباشرة من jard_audit_log عبر RPC في Supabase (بدل webhook n8n)
async function fetchDailyJardStats(dateFrom, dateTo, branch) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/get_jard_daily_stats`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'apikey': SB_ANON_API, 'Authorization': 'Bearer ' + SB_ANON_API },
      body: JSON.stringify({ p_from: dateFrom || null, p_to: (dateTo || dateFrom) || null, p_branch: branch || null })
    });
    if (!r.ok) return [];
    const data = await r.json();
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchDailyJardStats error:', e);
    return [];
  }
}

// ---- التقرير الشامل لكل عمليات الجرد (كل الفئات مع بعض) ----
const JARD_FULL_REPORT_URL = "https://agent.ebrahimhamdy.com/webhook/jard_full_report";
async function fetchFullJardReport({ branch, category, dateFrom, dateTo }) {
  try {
    const params = new URLSearchParams({ branch });
    if (category) params.set('category', category);
    if (dateFrom) params.set('date_from', dateFrom);
    if (dateTo)   params.set('date_to', dateTo);
    const response = await fetch(`${JARD_FULL_REPORT_URL}?${params.toString()}`);
    if (!response.ok) return [];
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchFullJardReport error:', e);
    return [];
  }
}

function logout() {
  // localStorage.clear() كان بيشيل كمان تفضيلات مش جلسة (الخط، الثيم،
  // عرض الأعمدة) فالمستخدم يرجع لإعدادات المصنع كل مرة. Session بيمسح
  // مفاتيح الجلسة بس.
  Session.logout('index.html');
}

// ===================== متابعة أرصدة الموردين (Supplier Balance Watch) =====================
// نفس أسلوب باقي الأبلكيشن: PostgREST بمفتاح anon. snapshots/runs = append-only (إضافة فقط).
// المرجع الحالي لأي فرع = أحدث صف في snapshots (بـ taken_at). التحقق من الصلاحية client-side.
const SB_SUPBAL_SNAP_URL = `${SB_URL_API}/rest/v1/supplier_balance_snapshots`;
const SB_SUPBAL_RUNS_URL = `${SB_URL_API}/rest/v1/supplier_balance_runs`;
const SB_SUPBAL_EXCL_URL = `${SB_URL_API}/rest/v1/supplier_balance_exclusions`;
const SB_SUPBAL_SET_URL  = `${SB_URL_API}/rest/v1/supplier_balance_settings`;

// صلاحيات الدور (نفس RPC اللي بيستخدمه الشل) — بترجّع [{page,can_view,can_edit}]
async function sbGetRolePages(role) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/get_role_pages`, {
      method: 'POST', headers: await sbH(), body: JSON.stringify({ p_role: role || '' })
    });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbGetRolePages error:', e); return []; }
}

// قائمة الفروع من جدول branches
async function sbBranches() {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/branches?select=name&order=name.asc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows.map(x => x.name).filter(Boolean) : [];
  } catch (e) { console.error('sbBranches error:', e); return []; }
}

// أحدث سناب شوتس لفرع (limit=2 يكفي: المرجع الحالي + اللي قبله للتراجع)
async function sbSupBalSnapshots(branch, limit) {
  try {
    const url = `${SB_SUPBAL_SNAP_URL}?select=id,branch,taken_at,taken_by,rows,rows_count,kind,restored_from`
      + `&branch=eq.${encodeURIComponent(branch)}&order=taken_at.desc,id.desc&limit=${limit || 2}`;
    const r = await fetch(url, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbSupBalSnapshots error:', e); return []; }
}

// أحدث مقارنة محفوظة لفرع (لعرض آخر نتيجة عند الفتح)
async function sbSupBalLatestRun(branch) {
  try {
    const url = `${SB_SUPBAL_RUNS_URL}?select=*&branch=eq.${encodeURIComponent(branch)}&order=run_at.desc,id.desc&limit=1`;
    const r = await fetch(url, { headers: await sbH() });
    if (!r.ok) return null;
    const rows = await r.json();
    return Array.isArray(rows) && rows.length ? rows[0] : null;
  } catch (e) { console.error('sbSupBalLatestRun error:', e); return null; }
}

// إضافة سناب شوت (كشف جديد كمرجع، أو صف تراجع) — بيرجّع الصف المُدرَج
async function sbSupBalInsertSnapshot({ branch, rows, rows_count, taken_by, kind, restored_from }) {
  try {
    const r = await fetch(SB_SUPBAL_SNAP_URL, {
      method: 'POST', headers: await sbH({ 'Prefer': 'return=representation' }),
      body: JSON.stringify({
        branch, rows: rows || {}, rows_count: rows_count || 0,
        taken_by: taken_by || null, kind: kind || 'import',
        restored_from: (restored_from != null ? restored_from : null)
      })
    });
    if (!r.ok) return null;
    const raw = await r.json();
    return Array.isArray(raw) ? (raw[0] || null) : raw;
  } catch (e) { console.error('sbSupBalInsertSnapshot error:', e); return null; }
}

// إضافة سجل مقارنة
async function sbSupBalInsertRun({ branch, run_by, changed_count, added_count, removed_count, result, snapshot_id }) {
  try {
    const r = await fetch(SB_SUPBAL_RUNS_URL, {
      method: 'POST', headers: await sbH({ 'Prefer': 'return=minimal' }),
      body: JSON.stringify({
        branch, run_by: run_by || null,
        changed_count: changed_count || 0, added_count: added_count || 0, removed_count: removed_count || 0,
        result: result || {}, snapshot_id: (snapshot_id != null ? snapshot_id : null)
      })
    });
    return r.ok;
  } catch (e) { console.error('sbSupBalInsertRun error:', e); return false; }
}

// الاستثناءات (قائمة عامة لكل الفروع)
async function sbSupBalExclusions() {
  try {
    const r = await fetch(`${SB_SUPBAL_EXCL_URL}?select=*&order=created_at.desc`, { headers: await sbH() });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbSupBalExclusions error:', e); return []; }
}
async function sbSupBalAddExclusion({ supplier_code, note, created_by }) {
  try {
    const r = await fetch(SB_SUPBAL_EXCL_URL, {
      method: 'POST', headers: await sbH({ 'Prefer': 'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify({ supplier_code: String(supplier_code), note: note || null, created_by: created_by || null })
    });
    return r.ok;
  } catch (e) { console.error('sbSupBalAddExclusion error:', e); return false; }
}
async function sbSupBalRemoveExclusion(supplier_code) {
  try {
    const r = await fetch(`${SB_SUPBAL_EXCL_URL}?supplier_code=eq.${encodeURIComponent(supplier_code)}`, {
      method: 'DELETE', headers: await sbH({ 'Prefer': 'return=minimal' })
    });
    return r.ok;
  } catch (e) { console.error('sbSupBalRemoveExclusion error:', e); return false; }
}

// الإعدادات المشتركة (حد تجاهل الفروق) — صف واحد id=1
async function sbSupBalSettings() {
  try {
    const r = await fetch(`${SB_SUPBAL_SET_URL}?select=*&id=eq.1`, { headers: await sbH() });
    if (!r.ok) return { threshold: 0.01 };
    const rows = await r.json();
    return (Array.isArray(rows) && rows[0]) ? rows[0] : { threshold: 0.01 };
  } catch (e) { console.error('sbSupBalSettings error:', e); return { threshold: 0.01 }; }
}
async function sbSupBalSaveSettings({ threshold, updated_by }) {
  try {
    const r = await fetch(SB_SUPBAL_SET_URL, {
      method: 'POST', headers: await sbH({ 'Prefer': 'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify({ id: 1, threshold: Number(threshold) || 0, updated_by: updated_by || null, updated_at: new Date().toISOString() })
    });
    return r.ok;
  } catch (e) { console.error('sbSupBalSaveSettings error:', e); return false; }
}


/* ===== أدوات الجداول العامة: تحجيم الأعمدة + محاذاة تلقائية على النص =====
   تُطبَّق تلقائيًا على أي <table> فيه رأس (thead/th)، وتتخطّى الجداول ذات
   التحكّم الخاص (طلبيات الأدوية) أو المعلّمة data-no-tabletools.
   - اسحب حدّ العمود  = تغيير العرض (قابل للتوسيع)
   - دبل كليك الحدّ   = محاذاة العمود تلقائيًا على أعرض نص فيه
   العرض محفوظ في المتصفح لكل شاشة/عمود. */
(function () {
  if (window.__tableToolsInit) return; window.__tableToolsInit = true;
  var PAGE = (location.pathname.split('/').pop() || 'page').replace(/[^a-z0-9]/gi, '_');

  var st = document.createElement('style');
  st.textContent =
    '.tt-rsz{position:absolute;top:0;left:0;width:9px;height:100%;cursor:col-resize;z-index:20;user-select:none}' +
    '.tt-rsz:hover{background:rgba(13,148,136,.35)}' +
    '.tt-sort{font-size:.7rem;margin-inline-start:4px;opacity:.3;user-select:none}';
  (document.head || document.documentElement).appendChild(st);

  function keyFor(tid, ci) { return 'tt_w::' + PAGE + '::' + tid + '::' + ci; }
  function tableId(t, i) { return t.id || ('tbl' + i); }
  function headRow(t) {
    if (t.tHead && t.tHead.rows.length) return t.tHead.rows[t.tHead.rows.length - 1];
    var r = t.rows[0];
    if (r && r.cells.length && r.cells[0].tagName === 'TH') return r;
    return null;
  }
  function skip(t) {
    if (t.hasAttribute('data-no-tabletools') || t.closest('[data-no-tabletools]')) return true;
    if (t.querySelector('.ord-rsz')) return true;   // شاشة لها تحكّم أعمدة خاص
    return false;
  }

  var RS = null;
  function onMove(e) {
    if (!RS) return;
    var dw = RS.startX - e.clientX;                 // RTL: المقبض على اليسار، السحب لليسار يوسّع
    var w = Math.max(30, RS.startW + dw);
    RS.th.style.width = w + 'px'; RS.w = w;
  }
  function onUp() {
    if (RS && RS.w) { try { localStorage.setItem(keyFor(RS.tid, RS.ci), Math.round(RS.w)); } catch (e) {} }
    RS = null;
    document.removeEventListener('mousemove', onMove);
    document.removeEventListener('mouseup', onUp);
    document.body.style.userSelect = '';
  }
  function startResize(e, tid, th, ci) {
    e.preventDefault(); e.stopPropagation();
    RS = { tid: tid, ci: ci, th: th, startX: e.clientX, startW: th.offsetWidth, w: 0 };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
    document.body.style.userSelect = 'none';
  }
  function autofit(t, tid, th, ci) {
    var max = 0, rows = t.rows;
    for (var i = 0; i < rows.length; i++) { var c = rows[i].cells[ci]; if (c && c.scrollWidth > max) max = c.scrollWidth; }
    if (max > 0) { var w = max + 14; th.style.width = w + 'px'; try { localStorage.setItem(keyFor(tid, ci), Math.round(w)); } catch (e) {} }
  }

  // ===== فرز عام بالضغط على الرأس (client-side لصفوف الجدول المعروضة) =====
  var sortState = (typeof WeakMap !== 'undefined') ? new WeakMap() : null;
  function ttNum(s) {
    var t = String(s).replace(/[٠-٩]/g, function (d) { return '٠١٢٣٤٥٦٧٨٩'.indexOf(d); }).replace(/[^\d.\-]/g, '');
    return t === '' || t === '-' || t === '.' ? null : Number(t);
  }
  function sortTable(t, hr, ci, ind) {
    var tb = t.tBodies[0]; if (!tb) return;
    var rows = Array.prototype.filter.call(tb.rows, function (r) { return r.cells.length === hr.cells.length; });
    if (rows.length < 2) return;
    var st = sortState ? (sortState.get(t) || { col: -1, dir: 0 }) : { col: -1, dir: 0 };
    var dir = (st.col === ci && st.dir === 1) ? -1 : 1;
    if (sortState) sortState.set(t, { col: ci, dir: dir });
    var vals = rows.map(function (r) { return r.cells[ci] ? r.cells[ci].textContent.trim() : ''; });
    var numeric = vals.every(function (v) { return v === '' || ttNum(v) !== null; }) && vals.some(function (v) { return ttNum(v) !== null; });
    rows.sort(function (a, b) {
      var va = a.cells[ci] ? a.cells[ci].textContent.trim() : '', vb = b.cells[ci] ? b.cells[ci].textContent.trim() : '', r;
      if (numeric) { var na = ttNum(va), nb = ttNum(vb); na = (na == null ? -Infinity : na); nb = (nb == null ? -Infinity : nb); r = na - nb; }
      else r = va.localeCompare(vb, 'ar');
      return r * dir;
    });
    rows.forEach(function (r) { tb.appendChild(r); });
    Array.prototype.forEach.call(hr.cells, function (th) { var s = th.querySelector('.tt-sort'); if (s) { s.textContent = '↕'; s.style.opacity = '.3'; } });
    if (ind) { ind.textContent = dir > 0 ? '▲' : '▼'; ind.style.opacity = '1'; }
  }
  function wireSort(t, hr) {
    if (t.hasAttribute('data-no-sort')) return;
    // الصفحة بتتحكّم في الفرز بنفسها (onclick على الرؤوس) → منتدخّلش
    if (Array.prototype.some.call(hr.cells, function (th) { return th.hasAttribute('onclick'); })) return;
    Array.prototype.forEach.call(hr.cells, function (th, ci) {
      if (th.querySelector('.tt-sort')) return;
      th.style.cursor = 'pointer';
      var ind = document.createElement('span'); ind.className = 'tt-sort'; ind.textContent = '↕';
      th.appendChild(ind);
      th.addEventListener('click', function (e) {
        if (e.target && e.target.classList && e.target.classList.contains('tt-rsz')) return;
        sortTable(t, hr, ci, ind);
      });
    });
  }

  function enhance(t, i) {
    if (t.__tt || skip(t)) return;
    var hr = headRow(t); if (!hr) return;
    t.__tt = true;
    var tid = tableId(t, i);
    Array.prototype.forEach.call(hr.cells, function (th, ci) {
      if (th.__tt) return; th.__tt = true;
      th.classList.add('tt-th');
      // لا نكسر sticky: نضبط relative فقط لو العمود static (بدون سياق تموضع)
      if (getComputedStyle(th).position === 'static') th.style.position = 'relative';
      var sv = localStorage.getItem(keyFor(tid, ci));
      if (sv) th.style.width = sv + 'px';
      var g = document.createElement('div');
      g.className = 'tt-rsz';
      g.title = 'اسحب لتغيير العرض — دبل كليك للمحاذاة على النص';
      g.addEventListener('mousedown', function (e) { startResize(e, tid, th, ci); });
      g.addEventListener('dblclick', function (e) { e.preventDefault(); e.stopPropagation(); autofit(t, tid, th, ci); });
      g.addEventListener('click', function (e) { e.stopPropagation(); });
      th.appendChild(g);
    });
    wireSort(t, hr);   // فرز عام (يتخطّى الجداول اللي بتفرز بنفسها server-side)
  }
  function scan() {
    var ts = document.querySelectorAll('table');
    for (var i = 0; i < ts.length; i++) enhance(ts[i], i);
  }
  function boot() {
    scan();
    try {
      var mo = new MutationObserver(function () { clearTimeout(window.__ttT); window.__ttT = setTimeout(scan, 300); });
      mo.observe(document.body, { childList: true, subtree: true });
    } catch (e) {}
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
