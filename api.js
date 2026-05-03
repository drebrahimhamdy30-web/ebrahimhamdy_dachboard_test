// 1. تعريف الروابط الأساسية (Webhooks)
const FETCH_URL = "https://agent.ebrahimhamdy.com/webhook/get_order";
const POST_URL = "https://agent.ebrahimhamdy.com/webhook/taskmanagement";
const LOGIN_URL = "https://agent.ebrahimhamdy.com/webhook/login"; 

// 2. دالة جلب البيانات العامة (تدعم كل الفئات)
async function fetchFromN8N(category) {
    try {
        // نرسل نوع البيانات المطلوب كـ Query Parameter (orders, inventory, transfers, etc.)
        const response = await fetch(`${FETCH_URL}?type=${category}`);
        if (!response.ok) throw new Error('Network error');
        const data = await response.json();
        
        // فحص هيكل البيانات لضمان الوصول للمصفوفة الصحيحة
        if (Array.isArray(data)) return data;
        if (data.data && Array.isArray(data.data)) return data.data;
        if (data[0] && data[0].data) return data[0].data;
        
        return [];
    } catch (error) {
        console.error(`Error fetching ${category}:`, error);
        return [];
    }
}

// اختصارات لجلب بيانات الشاشات المختلفة
const fetchOrders = () => fetchFromN8N('orders');     // النواقص والطلبات
const fetchInventory = () => fetchFromN8N('inventory'); // بيانات الجرد
const fetchTransfers = () => fetchFromN8N('transfers'); // تحويلات الفروع
const fetchPurchases = () => fetchFromN8N('purchases'); // المشتريات

// 3. دالة إرسال البيانات (POST) - نستخدمها لإضافة (طلب، تحويل، جرد)
async function postToN8N(payload) {
    try {
        // إضافة معلومات الفرع والمستخدم تلقائياً لكل عملية إرسال
        const enhancedPayload = {
            ...payload,
            branch: localStorage.getItem('userBranch') || 'Main',
            submittedBy: localStorage.getItem('activeUser') || 'Unknown',
            timestamp: new Date().toISOString()
        };

        const response = await fetch(POST_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(enhancedPayload)
        });
        return response.ok;
    } catch (error) {
        console.error("Submission Error:", error);
        return false;
    }
}

// 4. دالة تسجيل الدخول
async function login(username, password) {
    try {
        const response = await fetch(LOGIN_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'text/plain' },
            body: JSON.stringify({ user: username, pass: password })
        });

        if (!response.ok) return { success: false, message: "السيرفر لا يستجيب" };
        const result = await response.json();
        
        // إذا نجح الدخول، نخزن اسم المستخدم وفرعه
        if(result.success) {
            localStorage.setItem('activeUser', username);
            if(result.branch) localStorage.setItem('userBranch', result.branch);
        }
        return result;
    } catch (error) {
        return { success: false, message: "فشل الاتصال بالسيرفر" };
    }
}

// 5. حماية الصفحات (Authentication)
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
