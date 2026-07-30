const FETCH_URL     = "https://agent.ebrahimhamdy.com/webhook/get_order";
const POST_URL      = "https://agent.ebrahimhamdy.com/webhook/taskmanagement";
const LOGIN_URL     = "https://agent.ebrahimhamdy.com/webhook/login";
const VERIFY_URL    = "https://agent.ebrahimhamdy.com/webhook/verify_token";
const DASHBOARD_URL = "https://agent.ebrahimhamdy.com/webhook/dashboard";
const PAYMOB_URL    = "https://agent.ebrahimhamdy.com/webhook/paymobtransaction";

// بحث الصنف من مخزون Supabase مباشرة (بدل نداء ERP) — يرجّع {found,itm_name_ar,itm_name_en,balance,item_type}
const SB_URL_API  = "https://rxtjoqulmgkkcohmgzgi.supabase.co";
const SB_ANON_API = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0";
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
      headers: { ...SB_TASK_HEADERS, 'Prefer': 'return=representation' },
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
    const r = await fetch(`${SB_TASK_URL}?${params.toString()}`, { headers: SB_TASK_HEADERS });
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
      headers: SB_TASK_HEADERS,
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
async function sbContractInsert({ branch, cust_code, total_amount, notes }) {
  try {
    const chk = await fetch(
      `${SB_CONTRACT_URL}?select=id&cust_code=eq.${encodeURIComponent(cust_code || '')}&status=eq.block&limit=1`,
      { headers: SB_TASK_HEADERS }
    );
    if (chk.ok) {
      const rows = await chk.json();
      if (Array.isArray(rows) && rows.length) return { ok: false, blocked: true };
    }
    const r = await fetch(SB_CONTRACT_URL, {
      method: 'POST',
      headers: { ...SB_TASK_HEADERS, 'Prefer': 'return=minimal' },
      body: JSON.stringify({
        branch:       branch || null,
        cust_code:    cust_code || null,
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
      method: 'PATCH', headers: SB_TASK_HEADERS, body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbContractUpdate error:', e); return false; }
}

async function sbContractList() {
  try {
    const r = await fetch(`${SB_CONTRACT_URL}?select=*&order=created_at.desc`, { headers: SB_TASK_HEADERS });
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
      headers: { ...SB_TASK_HEADERS, 'Prefer': 'return=minimal' },
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
      method: 'PATCH', headers: SB_TASK_HEADERS, body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbMissingUpdate error:', e); return false; }
}

async function sbMissingList() {
  try {
    const r = await fetch(`${SB_MISSING_URL}?select=*&order=created_at.desc`, { headers: SB_TASK_HEADERS });
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
      headers: SB_TASK_HEADERS,
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
      method: 'POST', headers: SB_TASK_HEADERS, body: JSON.stringify(body || {})
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
function sbSalesByHour(from, to, store)        { return _sbRpc('sales_by_hour', { p_from: from||null, p_to: to||null, p_store: store||null }); }
// تحليل المبيعات — مراجعة الأسعار والخصومات
function sbSalesPriceReview(from, to, store)  { return _sbRpc('sales_price_review',  { p_from: from||null, p_to: to||null, p_store: store||null }); }
function sbSalesDiscountBills(from, to, store){ return _sbRpc('sales_discount_bills', { p_from: from||null, p_to: to||null, p_store: store||null }); }
const SB_SALES_URL = `${SB_URL_API}/rest/v1/sales_items`;
const SB_DISCREV_URL = `${SB_URL_API}/rest/v1/sales_discount_reviews`;
async function sbMarkPriceReviewed(id, by) {
  try {
    const r = await fetch(`${SB_SALES_URL}?id=eq.${encodeURIComponent(id)}`, {
      method:'PATCH', headers: SB_TASK_HEADERS,
      body: JSON.stringify({ price_reviewed:true, price_reviewed_at:new Date().toISOString(), price_reviewed_by: by||null })
    });
    return r.ok;
  } catch(e){ console.error('sbMarkPriceReviewed', e); return false; }
}
async function sbBillItems(store, billNo) {
  try {
    const url = `${SB_SALES_URL}?store_name=eq.${encodeURIComponent(store)}&bill_no=eq.${encodeURIComponent(billNo)}`
      + `&select=line_no,itm_code,itm_name_ar,unit_name,unit_price,itm_qty,line_total,itm_disc_value,itm_disc_perc,bill_notes&order=line_no.asc`;
    const r = await fetch(url, { headers: SB_TASK_HEADERS });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbBillItems', e); return []; }
}
async function sbMarkDiscountReviewed(store, billNo, by) {
  try {
    const r = await fetch(SB_DISCREV_URL, {
      method:'POST', headers:{ ...SB_TASK_HEADERS, 'Prefer':'resolution=merge-duplicates,return=minimal' },
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
    const r = await fetch(`${SB_SALES_ACCESS_URL}?select=store_name,enabled_at&order=store_name.asc`, { headers: SB_TASK_HEADERS });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch(e){ console.error('sbSalesAccessList', e); return []; }
}
// فتح الشاشة لفرع (upsert على store_name)
async function sbSalesAccessEnable(store) {
  try {
    const r = await fetch(SB_SALES_ACCESS_URL, {
      method:'POST', headers:{ ...SB_TASK_HEADERS, 'Prefer':'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify({ store_name: store })
    });
    return r.ok;
  } catch(e){ console.error('sbSalesAccessEnable', e); return false; }
}
// إغلاق الشاشة لفرع
async function sbSalesAccessDisable(store) {
  try {
    const r = await fetch(`${SB_SALES_ACCESS_URL}?store_name=eq.${encodeURIComponent(store)}`, {
      method:'DELETE', headers:{ ...SB_TASK_HEADERS, 'Prefer':'return=minimal' }
    });
    return r.ok;
  } catch(e){ console.error('sbSalesAccessDisable', e); return false; }
}

// طلبات خدمة العملاء لفرع — pendingOnly=true يرجّع بس اللي لسه محتاج إجراء (أسرع بكتير)
async function sbCsOrders(branch, pendingOnly) {
  try {
    const r = await fetch(`${SB_URL_API}/rest/v1/rpc/get_cs_orders`, {
      method: 'POST',
      headers: SB_TASK_HEADERS,
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
    const r = await fetch(`${SB_MATERIAL_URL}?select=*&order=name.asc,size.asc`, { headers: SB_TASK_HEADERS });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbMaterialList error:', e); return []; }
}

async function sbMaterialInsert({ name, size, price }) {
  try {
    const r = await fetch(SB_MATERIAL_URL, {
      method: 'POST',
      headers: { ...SB_TASK_HEADERS, 'Prefer': 'return=minimal' },
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
      method: 'PATCH', headers: SB_TASK_HEADERS, body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbMaterialUpdate error:', e); return false; }
}

async function sbMaterialDelete(id) {
  try {
    const r = await fetch(`${SB_MATERIAL_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'DELETE', headers: SB_TASK_HEADERS
    });
    return r.ok;
  } catch (e) { console.error('sbMaterialDelete error:', e); return false; }
}

// ===================== العروض على Supabase (بدل n8n) =====================
const SB_OFFERS_URL = `${SB_URL_API}/rest/v1/offers`;
async function sbOffersList() {
  try {
    const r = await fetch(`${SB_OFFERS_URL}?select=*&order=created_at.desc`, { headers: SB_TASK_HEADERS });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (e) { console.error('sbOffersList error:', e); return []; }
}
async function sbOfferInsert({ name, type, details, expires_at, branch }) {
  try {
    const r = await fetch(SB_OFFERS_URL, {
      method: 'POST', headers: { ...SB_TASK_HEADERS, 'Prefer': 'return=minimal' },
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
      method: 'PATCH', headers: SB_TASK_HEADERS, body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbOfferUpdate error:', e); return false; }
}
async function sbOfferDelete(id) {
  try {
    const r = await fetch(`${SB_OFFERS_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'DELETE', headers: SB_TASK_HEADERS
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
      method: 'POST', headers: SB_TASK_HEADERS,
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
      method: 'POST', headers: SB_TASK_HEADERS,
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
      method: 'POST', headers: { ...SB_TASK_HEADERS, 'Prefer': 'return=minimal' },
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
      method: 'PATCH', headers: SB_TASK_HEADERS, body: JSON.stringify(patch || {})
    });
    return r.ok;
  } catch (e) { console.error('sbStockLimitUpdate error:', e); return false; }
}
async function sbStockLimitDelete(id) {
  try {
    const r = await fetch(`${SB_STOCKLIMIT_URL}?id=eq.${encodeURIComponent(id)}`, {
      method: 'DELETE', headers: SB_TASK_HEADERS
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

async function login(username, password) {
  try {
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

async function verifyToken() {
  const token = localStorage.getItem('authToken');
  if (!token) return false;
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
    const r = await fetch(`${SB_URL_API}/rest/v1/app_control?id=eq.1&select=force_logout_before`, { headers: SB_TASK_HEADERS });
    if (!r.ok) return false;
    const rows = await r.json();
    const cutoff = (rows && rows[0] && rows[0].force_logout_before) ? new Date(rows[0].force_logout_before).getTime() : 0;
    const loginTime = parseInt(localStorage.getItem('loginTime') || '0', 10);
    if (cutoff && loginTime && loginTime < cutoff) {
      localStorage.clear();
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
    localStorage.clear();
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
const JARD_DAILY_STATS_URL = "https://agent.ebrahimhamdy.com/webhook/jard_daily_stats";
async function fetchDailyJardStats(dateFrom, dateTo, branch) {
  try {
    const params = new URLSearchParams();
    if (dateFrom) params.set('date_from', dateFrom);
    if (dateTo)   params.set('date_to', dateTo || dateFrom);
    if (branch)   params.set('branch', branch);
    const response = await fetch(`${JARD_DAILY_STATS_URL}?${params.toString()}`);
    if (!response.ok) return [];
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
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
  localStorage.clear();
  window.location.replace('index.html');
}
const POS_CLOSE_URL = "https://agent.ebrahimhamdy.com/webhook/pos_close";
 
// ---- 1) جلب وسائل الفرع + رصيد البداية + قيم النظام ----
// بيرجّع: { methods: [...], openings: { key: رقم }, system: { key: رقم } }
async function fetchPosCloseData(branch) {
  try {
    const params = new URLSearchParams({ action: 'get_close_data', branch });
    const response = await fetch(`${POS_CLOSE_URL}?${params.toString()}`);
    if (!response.ok) throw new Error('Network error');
    const text = await response.text();
    if (!text || text.trim() === '') return { methods: [], openings: {}, system: {} };
    const raw = JSON.parse(text);
    const data = Array.isArray(raw) ? (raw[0] || {}) : raw;
    return {
      methods:  data.methods  || [],
      openings: data.openings || {},
      system:   data.system   || {}
    };
  } catch (e) {
    console.error('fetchPosCloseData error:', e);
    throw e;
  }
}
 
// ---- 2) حفظ إغلاق شيفت ----
async function submitPosShift(payload) {
  try {
    const response = await fetch(POS_CLOSE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'close_shift', ...payload })
    });
    return response.ok;
  } catch (e) {
    console.error('submitPosShift error:', e);
    return false;
  }
}
 
// ---- 3) جلب الشيفتات غير المرحّلة ----
async function fetchUnsettledShifts(branch) {
  try {
    const params = new URLSearchParams({ action: 'get_unsettled', branch });
    const response = await fetch(`${POS_CLOSE_URL}?${params.toString()}`);
    if (!response.ok) return [];
    const text = await response.text();
    if (!text || text.trim() === '') return [];
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('fetchUnsettledShifts error:', e);
    return [];
  }
}
 
// ---- 4) ترحيل شيفت (المحاسب) ----
async function settlePosShift(shiftId, settledBy) {
  try {
    const response = await fetch(POS_CLOSE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action:     'settle_shift',
        shift_id:   shiftId,
        settled_by: settledBy
      })
    });
    return response.ok;
  } catch (e) {
    console.error('settlePosShift error:', e);
    return false;
  }
}
