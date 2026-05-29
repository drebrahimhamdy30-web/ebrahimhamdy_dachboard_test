const FETCH_URL     = "https://agent.ebrahimhamdy.com/webhook/get_order";
const POST_URL      = "https://agent.ebrahimhamdy.com/webhook/taskmanagement";
const LOGIN_URL     = "https://agent.ebrahimhamdy.com/webhook/login";
const VERIFY_URL    = "https://agent.ebrahimhamdy.com/webhook/verify_token";
const DASHBOARD_URL = "https://agent.ebrahimhamdy.com/webhook/dashboard";

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

async function fetchVisaTransactions() { return await fetchFromN8N('visa_transactions'); }
async function fetchMachines()         { return await fetchFromN8N('visa_machines'); }
async function fetchOrders()           { return await fetchFromN8N('orders'); }
async function fetchData()             { return await fetchFromN8N('orders'); }
async function fetchContracts()        { return await fetchFromN8N('contracts'); }
async function fetchMissing()          { return await fetchFromN8N('missing'); }
async function fetchInventory()        { return await fetchFromN8N('inventory'); }
async function fetchOffers()           { return await fetchFromN8N('offers'); }

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

async function checkAuth() {
  const user      = localStorage.getItem('activeUser');
  const token     = localStorage.getItem('authToken');
  const lastCheck = localStorage.getItem('lastVerify');
  const now       = Date.now();
  if (!user || !token) {
    window.location.replace('index.html');
    return null;
  }
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

function logout() {
  localStorage.clear();
  window.location.replace('index.html');
}
