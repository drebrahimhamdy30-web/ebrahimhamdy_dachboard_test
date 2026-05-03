// ===== API Configuration =====
const FETCH_URL = "https://agent.ebrahimhamdy.com/webhook/get_order";
const POST_URL  = "https://agent.ebrahimhamdy.com/webhook/taskmanagement";
const LOGIN_URL = "https://agent.ebrahimhamdy.com/webhook/login";

// ===== Fetch Data from n8n =====
async function fetchFromN8N(category) {
  try {
    const response = await fetch(`${FETCH_URL}?type=${category}`);
    if (!response.ok) throw new Error('Network error');
    const data = await response.json();
    if (Array.isArray(data)) return data;
    if (data.data && Array.isArray(data.data)) return data.data;
    if (data[0] && data[0].data) return data[0].data;
    return [];
  } catch (error) {
    console.error(`Error fetching ${category}:`, error);
    return [];
  }
}

async function fetchOrders() { return await fetchFromN8N('orders'); }
async function fetchData()   { return await fetchFromN8N('orders'); }

// ===== Login =====
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

// ===== Update / Insert Data =====
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

// ===== Auth Guard =====
function checkAuth() {
  const user = localStorage.getItem('activeUser');
  if (!user && !window.location.href.includes('index.html')) {
    window.location.replace('index.html');
    return null;
  }
  return user;
}

function logout() {
  localStorage.clear();
  window.location.replace('index.html');
}
