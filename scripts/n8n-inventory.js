#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   جرد عقد n8n اللي بتلمس قاعدة البيانات
   ═══════════════════════════════════════════════════════════════════
   بياخد ملف التصدير من `n8n export:workflow --all` وبيطلّع:
     • كل عقدة بتوصل للقاعدة، وبأي طريقة من الأربعة
     • هي على السحابة ولا على السيرفر دلوقتي
     • تشيك ليست جاهزة ليوم التحويل

   🔒 مابيطبعش أي سر: المفاتيح بتتعرض كطول بس، وكود العقد
      مابيتطبعش خالص — بنقول «فيه ختم مكتوب جوّه» وبس.

   بيتشغّل جوّه حاوية n8n (فيها node جاهز):
     docker cp n8n-inventory.js n8n:/tmp/
     docker exec n8n node /tmp/n8n-inventory.js /tmp/wf.json
   أو من scripts/n8n-inventory.sh اللي بيعمل ده كله.
   ═══════════════════════════════════════════════════════════════════ */
'use strict';
const fs = require('fs');

const CLOUD_REF = 'rxtjoqulmgkkcohmgzgi';
const SERVER_HOST = 'supabase.ebrahimhamdy.com';

const file = process.argv[2];
if (!file) { console.error('الاستعمال: node n8n-inventory.js <ملف التصدير>'); process.exit(1); }

let wfs;
try {
  wfs = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (e) {
  console.error('✗ مش قادر أقرا ملف التصدير: ' + e.message);
  process.exit(1);
}
if (!Array.isArray(wfs)) wfs = [wfs];

/* ── أدوات ───────────────────────────────────────────────────────── */

// بيلف على أي قيمة متداخلة ويرجّع كل النصوص
function walkStrings(v, out) {
  out = out || [];
  if (typeof v === 'string') out.push(v);
  else if (Array.isArray(v)) v.forEach(x => walkStrings(x, out));
  else if (v && typeof v === 'object') Object.values(v).forEach(x => walkStrings(x, out));
  return out;
}

function redactJwt(s) {
  return s.replace(/eyJ[A-Za-z0-9._-]{20,}/g, m => 'eyJ…(' + m.length + ' حرف)');
}

// الرابط من غير بارامترات — عشان مايطلعش توكن في كويري سترنج
function shortUrl(u) {
  try {
    const m = u.match(/^(https?:\/\/[^/\s]+)(\/[^\s?'"]*)?/);
    if (!m) return redactJwt(u).slice(0, 80);
    return m[1] + (m[2] || '');
  } catch (e) { return '؟'; }
}

function whereIsIt(str) {
  if (str.includes(SERVER_HOST)) return 'server';
  if (str.includes(CLOUD_REF) || /supabase\.co/.test(str)) return 'cloud';
  return null;
}

/* ── الفحص ───────────────────────────────────────────────────────── */

const rows = [];          // كل عقدة محتاجة شغل
const untouched = [];     // ورك فلوز مالهاش أي أثر للقاعدة خالص
const suspects  = [];     // مالقيناش فيها عقدة — بس فيها أثر. محتاجة عين بشرية
let nActive = 0;

for (const wf of wfs) {
  const nodes = Array.isArray(wf.nodes) ? wf.nodes : [];
  if (wf.active) nActive++;
  let hit = false;

  for (const n of nodes) {
    const type = String(n.type || '');
    const params = n.parameters || {};
    const strs = walkStrings(params);
    const creds = n.credentials || {};
    const credTypes = Object.keys(creds);

    const kinds = [];   // إيه اللي لازم يتغيّر في العقدة دي
    let target = null;  // على السحابة ولا السيرفر
    let credName = "";  // اسم الكريدنشيال — بيتجمّع عليه الشغل
    let detail = '';

    // 1) كريدنشيال Supabase
    const supaCred = credTypes.find(k => /supabase/i.test(k));
    if (supaCred) {
      kinds.push('كريدنشيال Supabase');
      credName = (creds[supaCred] && creds[supaCred].name) || supaCred;
      detail = credName;
    }

    // 2) كريدنشيال Postgres / عقدة postgres
    const pgCred = credTypes.find(k => /postgres/i.test(k));
    if (pgCred || /postgres/i.test(type)) {
      kinds.push('كريدنشيال Postgres');
      credName = credName || (pgCred && creds[pgCred] && creds[pgCred].name) || 'عقدة Postgres';
      if (!detail) detail = credName;
      target = target || 'db-direct';
    }

    // 3) رابط مكتوب جوّه العقدة
    //    ⚠️ مش كفاية ندوّر على https:// — فيه عقد بتبني الرابط بتعبير
    //    {{ }} أو بتاخده من متغيّر بيئة، فالمضيف مش مكتوب أصلًا.
    //    دول أخطر نوع (مزامنة فاضلة على السحابة بتكتب بصمت) فلازم
    //    نمسكهم من المسار نفسه: /rest/v1/ أو /auth/v1/.
    const urls = strs.filter(s => /^https?:\/\//.test(s.trim()) || /\/(rest|auth)\/v1\b/.test(s));
    const dbUrls = urls.filter(u => whereIsIt(u) || /\/(rest|auth)\/v1\b/.test(u));
    if (dbUrls.length) {
      kinds.push('رابط مكتوب في العقدة');
      // لو فيه مضيف صريح في أي واحد منهم خده، وإلا يبقى رابط بتعبير
      target = whereIsIt(dbUrls.join(' ')) || target || 'expr';
      detail = shortUrl(dbUrls[0]);
    }

    // 4) ختم JWT مكتوب صريح في كود العقدة
    //    بندوّر على تعريف سر في الكود — مش على استعمال متغيّر بيئة
    const code = strs.join('\n');
    const hasInlineSecret =
      /(?:secret|SECRET|JWT_SECRET)\s*[:=]\s*['"`][^'"`\n]{16,}['"`]/.test(code) ||
      /sign\s*\(/.test(code) && /['"`][A-Za-z0-9+/=_-]{24,}['"`]/.test(code);
    if (hasInlineSecret) {
      kinds.push('🔑 ختم مكتوب في الكود');
      if (!detail) detail = 'كود العقدة';
    }

    // مفتاح service_role ظاهر كنص في العقدة
    const jwtLiteral = strs.find(s => /^eyJ[A-Za-z0-9._-]{40,}$/.test(s.trim()));
    if (jwtLiteral) {
      kinds.push('مفتاح مكتوب في العقدة');
      if (!target) target = 'cloud';
      detail = detail || redactJwt(jwtLiteral);
    }

    if (!kinds.length) continue;
    hit = true;
    rows.push({
      wf: wf.name || '(بلا اسم)',
      active: !!wf.active,
      node: n.name || '(بلا اسم)',
      type: type.replace(/^n8n-nodes-base\./, ''),
      kinds,
      target,
      cred: credName,
      detail: redactJwt(detail).slice(0, 110),
    });
  }

  if (!hit) {
    // ── شبكة أمان ──────────────────────────────────────────────────
    // لو مفيش أي عقدة اتمسكت، بندوّر في نص الورك فلو كله على أي أثر
    // للقاعدة. الورك فلو اللي بيطلع هنا **مش** مطمَّن عليه — يعني
    // «مالقيتش» مش «مفيش». الفرق ده مهم: أول نسخة من الأداة قالت إن
    // «sync customers balances -> supabase» مالهاش علاقة بالقاعدة.
    const raw = JSON.stringify(wf);
    const marks = [];
    if (/supabase/i.test(raw)) marks.push('supabase');
    if (new RegExp(CLOUD_REF, 'i').test(raw)) marks.push('السحابة');
    if (new RegExp(SERVER_HOST.replace(/\./g, '\\.'), 'i').test(raw)) marks.push('السيرفر');
    if (/\/(rest|auth)\/v1\b/.test(raw)) marks.push('rest/v1');
    if (/postgres|\bpg\b|sql/i.test(raw)) marks.push('sql');
    if (/executeWorkflow/i.test(raw)) marks.push('بينده ورك فلو تاني');
    if (marks.length) suspects.push({ name: wf.name || '(بلا اسم)', active: !!wf.active, marks });
    else untouched.push({ name: wf.name || '(بلا اسم)', active: !!wf.active });
  }
}

/* ── العرض ───────────────────────────────────────────────────────── */

const bold = s => '\u001b[1m' + s + '\u001b[0m';
const dim  = s => '\u001b[2m' + s + '\u001b[0m';

const activeRows = rows.filter(r => r.active);
const cloudRows  = activeRows.filter(r => r.target === 'cloud');
const serverRows = activeRows.filter(r => r.target === 'server');
const dbRows     = activeRows.filter(r => r.target === 'db-direct');
const secretRows = activeRows.filter(r => r.kinds.some(k => k.includes('ختم')));

console.log('');
console.log(bold('══ جرد n8n ══'));
console.log('  ورك فلوز كلها      : ' + wfs.length + '   (نشطة: ' + nActive + ')');
console.log('  عقد بتلمس القاعدة  : ' + rows.length + '   (في ورك فلوز نشطة: ' + activeRows.length + ')');
console.log('');
console.log('  منها — على السحابة : ' + bold(String(cloudRows.length)) + '   ← دي اللي لازم تتحوّل');
console.log('         على السيرفر : ' + serverRows.length + (serverRows.length ? '   (اتحوّلت خلاص)' : ''));
console.log('         اتصال مباشر : ' + dbRows.length + '   ← كريدنشيال Postgres');
console.log('         ختم في الكود: ' + secretRows.length + '   ← ' + (secretRows.length ? bold('أخطر بند — بيفشل بـ401 مضلّل') : 'ولا واحد'));

/* ── أهم جدول: الكريدنشيالات ──────────────────────────────────────
   دي الصورة اللي بتحدّد حجم الشغل الحقيقي. عشرات العقد بتشترك في
   كريدنشيال واحد، فتغييره بيحرّكهم كلهم مرة واحدة — بس بنفس المنطق
   أي غلطة فيه بتوقّفهم كلهم مرة واحدة. فبعد التغيير: شغّل عقدة
   واحدة يدوي واتأكد قبل ما تكمّل. */
const byCred = {};
for (const r of activeRows) {
  const c = r.kinds.find(k => k.startsWith('كريدنشيال'));
  if (!c) continue;
  const key = c + ' — ' + (r.cred || '؟');
  byCred[key] = byCred[key] || { nodes: 0, wfs: new Set() };
  byCred[key].nodes++;
  byCred[key].wfs.add(r.wf);
}
const credKeys = Object.keys(byCred).sort((a, b) => byCred[b].nodes - byCred[a].nodes);
if (credKeys.length) {
  console.log('');
  console.log(bold('══ الكريدنشيالات — تعديل واحد بيحرّك كام عقدة ══'));
  for (const k of credKeys) {
    console.log('  ' + bold(String(byCred[k].nodes).padStart(3)) + ' عقدة  في ' +
                String(byCred[k].wfs.size).padStart(2) + ' ورك فلو   ← ' + k);
  }
  console.log(dim('  ⚠️ غلطة في كريدنشيال واحد = كل العقد دي تقف مرة واحدة.'));
  console.log(dim('     غيّره، شغّل عقدة واحدة يدوي، اتأكد، وبعدين كمّل.'));
}

// جدول مجمّع بالورك فلو
console.log('');
console.log(bold('══ التفصيل (الورك فلوز النشطة) ══'));
const byWf = {};
for (const r of activeRows) (byWf[r.wf] = byWf[r.wf] || []).push(r);
const names = Object.keys(byWf).sort();
if (!names.length) console.log('  (مفيش)');
for (const nm of names) {
  const list = byWf[nm];
  const flags = list.some(r => r.target !== 'server') ? '🔴' : '✅';
  console.log('');
  console.log('  ' + flags + ' ' + bold(nm));
  for (const r of list) {
    const where = r.target === 'cloud' ? 'السحابة' : r.target === 'server' ? 'السيرفر' : r.target === 'db-direct' ? 'مباشر' : r.target === 'expr' ? 'رابط بتعبير — افحصه بإيدك' : '—';
    console.log('      • ' + r.node + dim('  [' + r.type + ']'));
    console.log('        ' + r.kinds.join(' + ') + '   ← ' + where);
    if (r.detail) console.log(dim('        ' + r.detail));
  }
}

// ── مشتبه فيها: فيها أثر للقاعدة بس مالقيناش العقدة ────────────────
const suspectActive = suspects.filter(u => u.active);
if (suspectActive.length) {
  console.log('');
  console.log(bold('══ 🟡 محتاجة عين بشرية (' + suspectActive.length + ') ══'));
  console.log('  فيها أثر للقاعدة بس مالقيتش فيها عقدة أقدر أصنّفها — غالبًا');
  console.log('  الرابط متبني بتعبير {{ }} أو جاي من متغيّر بيئة.');
  console.log('  ' + bold('افتحها بإيدك.') + ' «مالقيتش» ≠ «مفيش».');
  for (const u of suspectActive) {
    console.log('      • ' + u.name + dim('   [' + u.marks.join(' · ') + ']'));
  }
}

// ورك فلوز نشطة مافيهاش أي أثر للقاعدة خالص
const untouchedActive = untouched.filter(u => u.active);
if (untouchedActive.length) {
  console.log('');
  console.log(dim('══ ورك فلوز نشطة مافيهاش أي أثر للقاعدة (' + untouchedActive.length + ') ══'));
  console.log(dim('  ' + untouchedActive.map(u => u.name).join(' · ')));
}

/* ── تشيك ليست ليوم التحويل ──────────────────────────────────────── */

const out = [];
out.push('# تشيك ليست n8n — يوم التحويل');
out.push('');
out.push('اتولّدت من التصدير الحي في ' + new Date().toISOString().slice(0, 10) + ' · ' +
         cloudRows.length + ' عقدة لسه على السحابة');
out.push('');
out.push('> بعد كل ورك فلو: شغّل اختبار واحد وشوف تبويب Executions.');
out.push('> العقدة الحمرا ورسالتها أسرع من أي تخمين.');
out.push('');
for (const nm of names) {
  const list = byWf[nm].filter(r => r.target !== 'server');
  if (!list.length) continue;
  out.push('## ' + nm);
  out.push('');
  for (const r of list) {
    out.push('- [ ] **' + r.node + '** — ' + r.kinds.join(' + ') +
             (r.detail ? '  \n      `' + r.detail + '`' : ''));
  }
  out.push('');
}
if (credKeys.length) {
  out.push('## الكريدنشيالات (ابدأ بيها — أكبر أثر بأقل تعديل)');
  out.push('');
  for (const k of credKeys) {
    out.push('- [ ] **' + k + '** — ' + byCred[k].nodes + ' عقدة في ' + byCred[k].wfs.size + ' ورك فلو');
  }
  out.push('');
  out.push('> غيّر الكريدنشيال، شغّل **عقدة واحدة** يدوي، اتأكد، وبعدين كمّل.');
  out.push('> غلطة في كريدنشيال واحد بتوقّف كل العقد دي مرة واحدة.');
  out.push('');
}
if (suspectActive.length) {
  out.push('## 🟡 افتحها بإيدك — مالقيتش فيها عقدة أصنّفها');
  out.push('');
  out.push('الأداة بتدوّر على مضيف مكتوب صريح. العقدة اللي بتبني الرابط بتعبير');
  out.push('`{{ }}` أو بتاخده من متغيّر بيئة مابتتمسكش. **«مالقيتش» ≠ «مفيش».**');
  out.push('');
  for (const u of suspectActive) {
    out.push('- [ ] **' + u.name + '** — أثر: ' + u.marks.join(' · '));
  }
  out.push('');
}
out.push('## بعد ما تخلص');
out.push('');
out.push('- [ ] سجّل دخول بحساب طيار تجريبي من التطبيق (لو «لم يتم العثور على بيانات السائق» → الختم لسه غلط)');
out.push('- [ ] شغّل كل ورك فلو مزامنة **مرة يدوي** وشوف الصفوف وصلت السيرفر مش السحابة');
out.push('- [ ] ⚠️ أي ورك فلو فضل على السحابة **مش هيرمي خطأ** — هيكتب في قاعدة متجمّدة بصمت');
out.push('');

const dest = process.env.N8N_CHECKLIST || '/tmp/n8n_cutover_checklist.md';
try {
  fs.writeFileSync(dest, out.join('\n'));
  console.log('');
  console.log('📋 التشيك ليست اتكتبت في: ' + dest);
} catch (e) {
  console.log('');
  console.log('⚠️ مقدرتش أكتب التشيك ليست: ' + e.message);
}
console.log('');
