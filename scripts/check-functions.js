#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   فحص سلامة دوال Edge المصدَّرة
   ═══════════════════════════════════════════════════════════════════
   الدوال اتنسخت يدويًا من السحابة للريبو. الخطر إن حاجة تضيع في النقل
   ومحدش يلاحظ لحد ما الدالة تتنشر على السيرفر وتفشل.

   ⚠️ **حدود الفحص ده — اقراها:**
   الفحص هنا **بنيوي مش نحوي**. جرّبت أعمل فحص «كل دالة بتتنادى لازم
   تكون معرَّفة» بـregex وطلع غلط في كل الملفات: `async` و`in` و`of`
   كلمات محجوزة اتحسبت نداءات، ودوال معرَّفة جوه كائن (`minus`/`format`)
   اتحسبت نداءات، والأنواع العامة `<T,R>` كسرت التقاط المعاملات.
   **تحليل TypeScript بـregex مايشتغلش** — والفاحص الغلط أسوأ من مفيش
   فاحص لأنه بيدّي ثقة كاذبة.

   الفحص النحوي الحقيقي مكانه وقت النشر:
       deno check supabase/functions/<slug>/index.ts
   والمبرمج عنده Deno جوه حاوية edge-runtime أصلًا.

   الاستعمال:  node scripts/check-functions.js
   ═══════════════════════════════════════════════════════════════════ */
const fs = require('fs'), path = require('path');

const DIR = path.join(process.cwd(), 'supabase', 'functions');
if (!fs.existsSync(DIR)) { console.log('مفيش مجلد supabase/functions'); process.exit(0); }

let problems = 0, checked = 0;
const seen = [];

for (const e of fs.readdirSync(DIR, { withFileTypes: true })) {
  if (!e.isDirectory()) continue;
  const slug = e.name;
  const fp = path.join(DIR, slug, 'index.ts');
  if (!fs.existsSync(fp)) { console.log(`  ❌ ${slug}: مفيش index.ts`); problems++; continue; }
  checked++;
  const src = fs.readFileSync(fp, 'utf8');
  const issues = [];

  // 1) الملف مش فاضي ولا مبتور
  if (src.length < 200) issues.push(`الملف صغير جدًا (${src.length} حرف) — يمكن مبتور`);

  // 2) نقطة الدخول موجودة
  if (!/Deno\.serve\s*\(/.test(src)) issues.push('مفيش Deno.serve — الدالة مالهاش نقطة دخول');

  // 3) بينتهي بشكل سليم (مش مقطوع في النص)
  if (!/\}\s*\)?\s*;?\s*$/.test(src.trimEnd())) issues.push('الملف بينتهي بشكل غريب — يمكن مبتور');

  // 4) سر مكتوب صريح (بعد شيل التعليقات)
  const code = src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*\/\/.*$/gm, ' ');
  if (/\b(?:secret|token|password|apikey|api_key)\s*[:=]\s*["'][A-Za-z0-9_./+-]{20,}["']/i.test(code))
    issues.push('⚠️ سر مكتوب صريح — الريبو عام');

  // 5) الميتاداتا
  const mp = path.join(DIR, slug, '.meta.json');
  if (!fs.existsSync(mp)) issues.push('مفيش .meta.json — verify_jwt هيتظبط بالتخمين عند النشر');
  else {
    try {
      const m = JSON.parse(fs.readFileSync(mp, 'utf8'));
      if (typeof m.verify_jwt !== 'boolean') issues.push('verify_jwt مش boolean');
      if (m.slug !== slug) issues.push(`slug في .meta.json (${m.slug}) مش مطابق لاسم المجلد`);
      seen.push({ slug, jwt: m.verify_jwt, bytes: src.length });
    } catch (err) { issues.push('.meta.json مش JSON سليم'); }
  }

  if (issues.length) { problems++; console.log(`  ❌ ${slug}`); issues.forEach(i => console.log(`       ${i}`)); }
  else console.log(`  ✅ ${slug.padEnd(22)} ${String(src.length).padStart(6)} بايت`);
}

// ملخّص verify_jwt — غلطة هنا بتفتح دالة للعامة أو تقفل دالة مطلوبة
const open = seen.filter(s => !s.jwt).map(s => s.slug);
console.log(`\nverify_jwt=false (مفتوحة بلا توكن، الحراسة جوّه الكود): ${open.length}`);
console.log('  ' + open.join(' · '));

console.log(problems ? `\n⛔ ${problems} من ${checked} فيهم مشاكل` : `\n✅ ${checked} دالة عدّت الفحص البنيوي`);
console.log('   ⚠️ الفحص ده مش نحوي — للتأكد من الصياغة: deno check');
process.exit(problems ? 1 : 0);
