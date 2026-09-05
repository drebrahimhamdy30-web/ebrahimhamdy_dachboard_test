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
  // ⚠️⚠️ الريبو ده (التست) بيشتغل على **السيرفر الخاص**، مش السحابة.
  //   البرودكشن (ebrahimhamdy_dachboard) لسه على سحابة Supabase.
  //   دي **أول مرة** الملفين يختلفوا بين الريبوهين عن قصد —
  //   ماتزامنهوش تلقائيًا وإلا التست هيرجع على السحابة من غير ما حد ياخد باله.
  //
  //   للرجوع للسحابة: بدّل السطرين دول بقيم البرودكشن.
  // خادم Supabase — السيرفر الخاص
  supabaseUrl:     'https://supabase.ebrahimhamdy.com',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg4MzI1MDA0LCJleHAiOjE5NDYwMDUwMDR9.Yx-kNhTDLh9fLku8AAdVnx1ir_xzT1uToO9XJdZ7d7I',

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
