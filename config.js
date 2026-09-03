/* ═══════════════════════════════════════════════════════════════════
   إعدادات Phalix — المصدر الوحيد لعناوين الخوادم والمفاتيح
   ═══════════════════════════════════════════════════════════════════
   أي تغيير في الخادم أو المفتاح يتعمل هنا **بس**، ويسري على كل الشاشات.

   ⚠️ الملف ده لازم يتحمّل **قبل** api.js و supabase-config.js وأي كود
      بيستعمل الثوابت دي:
          <script src="config.js?v=..."></script>
          <script src="api.js?v=..."></script>

   ملاحظة: المفتاح ده عام (anon) ومقصود إنه يبان في الصفحات — الحماية
   الحقيقية في سياسات RLS وحراسة الدوال على الخادم، مش في إخفاء المفتاح.
   ═══════════════════════════════════════════════════════════════════ */

const PHALIX_CONFIG = {
  // خادم Supabase — غيّر ده لما تنقل لخادم تاني
  supabaseUrl:     'https://rxtjoqulmgkkcohmgzgi.supabase.co',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0',

  // خادم n8n — لسه بيشغّل الدخول وبعض التكاملات
  n8nBase: 'https://agent.ebrahimhamdy.com'
};

/* ── أسماء متوافقة مع الكود القائم ──────────────────────────────────
   الشاشات اتكتبت على مدى طويل بتسميات مختلفة لنفس القيمة. بنعرّفها
   كلها هنا من مصدر واحد بدل ما كل صفحة تكتب القيمة بنفسها.        */
const SB_URL_API   = PHALIX_CONFIG.supabaseUrl;      // api.js وصفحات الـERP
const SB_ANON_API  = PHALIX_CONFIG.supabaseAnonKey;
const SUPABASE_URL = PHALIX_CONFIG.supabaseUrl;      // صفحات التوصيل
const SUPABASE_KEY = PHALIX_CONFIG.supabaseAnonKey;
const SB_URL       = PHALIX_CONFIG.supabaseUrl;      // شاشات الشيفتات والتكاملات
const SB_KEY       = PHALIX_CONFIG.supabaseAnonKey;

// أساس ويبهوكات n8n — استعمل n8nUrl('login') بدل كتابة الرابط كامل
const N8N_BASE = PHALIX_CONFIG.n8nBase;
function n8nUrl(path) {
  return PHALIX_CONFIG.n8nBase + '/webhook/' + String(path || '').replace(/^\/+/, '');
}

// رابط Edge Function — نفس فكرة edge_url() في قاعدة البيانات
function edgeUrl(fn) {
  return PHALIX_CONFIG.supabaseUrl + '/functions/v1/' + String(fn || '').replace(/^\/+/, '');
}
