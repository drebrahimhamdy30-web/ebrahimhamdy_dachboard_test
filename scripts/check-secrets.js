#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   فحص الأسرار قبل أي push — الريبو ده **عام**
   ═══════════════════════════════════════════════════════════════════
   سابقة: توكن db-backup اتكتب صريح في ملف الدالة واترفع هنا، فبقى
   مقروء لأي حد على الإنترنت. الفحص ده بيمنع تكرارها.

   الاستعمال:
       node scripts/check-secrets.js          # يفحص كل الريبو
       node scripts/check-secrets.js --staged # يفحص اللي في الـstaging بس

   بيرجّع كود خروج 1 لو لقى حاجة — يعني ينفع يتحط في pre-commit hook.
   ═══════════════════════════════════════════════════════════════════ */
const fs = require('fs'), path = require('path'), cp = require('child_process');

const ROOT = process.cwd();
const STAGED = process.argv.includes('--staged');

/* أنماط الأسرار. المفتاح العام (anon) مستثنى عن قصد — ده مقصود إنه
   يبان في الصفحات، والحماية الحقيقية في RLS وحراسة الدوال. */
const RULES = [
  { name: 'توكن Phalix',        re: /phlx_[a-z]{2,4}_[A-Za-z0-9]{12,}/g },
  { name: 'مفتاح service_role', re: /"role"\s*:\s*"service_role"/g },
  { name: 'JWT كامل',           re: /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/g },
  { name: 'مفتاح خاص PEM',      re: /-----BEGIN (RSA |EC )?PRIVATE KEY-----/g },
  { name: 'ثابت طويل مشبوه',    re: /\b(?:token|secret|key|password|passwd|pwd|apikey|api_key)\s*[:=]\s*["'][A-Za-z0-9_./+-]{20,}["']/gi },
  { name: 'رابط فيه كلمة سر',   re: /(?:postgres|postgresql|mysql|mongodb):\/\/[^:\s]+:[^@\s]+@/g }
];

/* استثناءات مقصودة: المفتاح العام و boundary مش أسرار */
const ALLOW = [
  /supabaseAnonKey/,            // config.js — مفتاح anon عام بقصد
  /BOUNDARY\s*=/,               // فاصل multipart مش سر
  /CHANGE_ME/,                  // قيمة نائبة
  /Deno\.env\.get/,             // بيقرا من البيئة = سليم
  /decrypted_secret/            // بيقرا من vault = سليم
];

function files() {
  if (STAGED) {
    return cp.execSync('git diff --cached --name-only --diff-filter=ACM', { encoding: 'utf8' })
      .split('\n').map(s => s.trim()).filter(Boolean)
      .filter(f => /\.(ts|js|html|css|json|sql|md|yml|yaml|sh)$/i.test(f))
      .filter(f => fs.existsSync(path.join(ROOT, f)));
  }
  const out = [];
  // الملفات المتجاهلة في git (زي .mcp.json) مش هتترفع أصلًا — بنتخطاها
  // عشان التقرير مايمتلئش بإنذارات مش هتوصل GitHub.
  let ignored = new Set();
  try {
    ignored = new Set(
      cp.execSync('git ls-files --others --ignored --exclude-standard', { encoding: 'utf8' })
        .split(/\r?\n/).map(s => s.trim()).filter(Boolean));
  } catch (e) { /* مش ريبو git — نفحص كل حاجة */ }
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (['.git', 'node_modules'].includes(e.name)) continue;
      const fp = path.join(d, e.name);
      if (e.isDirectory()) { walk(fp); continue; }
      const r = path.relative(ROOT, fp).replace(/\\/g, '/');
      if (ignored.has(r)) continue;
      if (/\.(ts|js|html|css|json|sql|md|yml|yaml|sh)$/i.test(e.name)) out.push(r);
    }
  })(ROOT);
  return out;
}

let hits = 0;
for (const rel of files()) {
  let s;
  try { s = fs.readFileSync(path.join(ROOT, rel), 'utf8'); } catch (e) { continue; }
  const lines = s.split(/\r?\n/);
  lines.forEach((line, i) => {
    if (ALLOW.some(a => a.test(line))) return;
    for (const r of RULES) {
      r.re.lastIndex = 0;
      const m = r.re.exec(line);
      if (m) {
        hits++;
        console.log(`  ❌ ${rel}:${i + 1}  [${r.name}]`);
        console.log(`     ${line.trim().slice(0, 100)}`);
      }
    }
  });
}

if (hits) {
  console.log(`\n⛔ ${hits} سر محتمل. الريبو ده **عام** — مايتعملش push.`);
  console.log('   الأسرار مكانها: متغيّرات بيئة الدالة، أو vault في قاعدة البيانات.');
  process.exit(1);
}
console.log('✅ مفيش أسرار في الملفات المفحوصة');
