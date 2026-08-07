/* تست منطق تحليل/مقارنة أرصدة الموردين — Node، بدون أي مكتبات.
 * التشغيل:  node tests/supplier_balances_parser.test.js
 * الخروج بكود 1 لو أي تأكيد فشل.
 *
 * العيّنة بتغطّي: سطر عناوين (بترتيب أعمدة مختلف عن الافتراضي)، سالب بشكل 1.000-،
 * سالب بالأقواس، أرقام عربية، أعمدة فاضية، كود نصّي (A12)، سطور فاضية، وسطور تتخطّى
 * (كود عربي غير صالح + رصيد غير رقمي).
 */
const assert = require('assert');
const { parse, toNum, compare } = require('../supplier_balances_parser.js');

let pass = 0;
const ok = (name, fn) => { try { fn(); pass++; console.log('  ✓ ' + name); }
  catch (e) { console.error('  ✗ ' + name + '\n      ' + e.message); process.exitCode = 1; } };

// ---- عيّنة حقيقية: أعمدة بترتيب [كود، اسم عربي، اسم EN، المسحوبات، حد المسحوبات، تليفون، مدير] ----
const T = '\t';
const sample = [
  ['كود','الاسم (عربي)','الاسم (EN)','المسحوبات الحالية','حد المسحوبات','التليفون','المدير'].join(T),
  ['100','مورد ألفا','Alpha Co','1500.000','2000','01000000000','أحمد'].join(T),
  ['200','مورد بيتا','Beta','1.000-','0','','سمير'].join(T),          // سالب بشكل 1.000-
  ['300','مورد جاما','','(500.000)','','',''].join(T),                // سالب بالأقواس + أعمدة فاضية
  ['A12','مورد دلتا','Delta','٧٥٠٫٥٠٠','1000','',''].join(T),         // أرقام عربية + كود نصّي
  '',                                                                  // سطر فاضي
  ['الإجمالي','','','9999','','',''].join(T),                         // كود غير صالح -> يتخطّى
  ['999','مورد باظ','Bad','abc','','',''].join(T)                     // رصيد غير رقمي -> يتخطّى
].join('\n');

console.log('parse():');
const res = parse(sample);
ok('اكتشف سطر العناوين', () => assert.strictEqual(res.foundHeader, true));
ok('قرأ 4 موردين صالحين', () => assert.strictEqual(res.count, 4));
ok('تخطّى سطرين غير صالحين', () => assert.strictEqual(res.skipped, 2));
ok('رصيد موجب عادي', () => assert.strictEqual(res.rows['100'].b, 1500));
ok('سالب بشكل 1.000-', () => assert.strictEqual(res.rows['200'].b, -1));
ok('سالب بالأقواس (500.000)', () => assert.strictEqual(res.rows['300'].b, -500));
ok('أرقام عربية ٧٥٠٫٥٠٠', () => assert.strictEqual(res.rows['A12'].b, 750.5));
ok('كود نصّي A12 اتقرأ', () => assert.ok(res.rows['A12']));
ok('عمود EN الفاضي = ""', () => assert.strictEqual(res.rows['300'].e, ''));
ok('عمود التليفون الفاضي = ""', () => assert.strictEqual(res.rows['200'].p, ''));

console.log('toNum():');
ok("'1.000-'  = -1",      () => assert.strictEqual(toNum('1.000-'), -1));
ok("'-1.000'  = -1",      () => assert.strictEqual(toNum('-1.000'), -1));
ok("'(500.000)' = -500",  () => assert.strictEqual(toNum('(500.000)'), -500));
ok("'١٢٣'     = 123",     () => assert.strictEqual(toNum('١٢٣'), 123));
ok("'1,234.5' = 1234.5",  () => assert.strictEqual(toNum('1,234.5'), 1234.5));
ok("''        = NaN",     () => assert.ok(Number.isNaN(toNum(''))));
ok("'abc'     = NaN",     () => assert.ok(Number.isNaN(toNum('abc'))));

console.log('compare():');
const oldSnap = res.rows;
const newSnap = {
  '100': { b: 1600, a: 'مورد ألفا', e: 'Alpha Co', p: '' },   // +100 -> اتغيّر
  '200': { b: -1,   a: 'مورد بيتا', e: 'Beta', p: '' },        // نفسه -> ثابت
  '300': { b: -500.005, a: 'مورد جاما', e: '', p: '' },        // فرق 0.005 < الحد -> يتجاهل
  // A12 مش موجود -> removed
  '400': { b: 250, a: 'مورد جديد', e: 'New', p: '' }           // جديد -> added
};
const cmp = compare(oldSnap, newSnap, { threshold: 0.01, exclusions: [] });
ok('صنف واحد اتغيّر (100)', () => { assert.strictEqual(cmp.changed.length, 1); assert.strictEqual(cmp.changed[0].code, '100'); });
ok('فرق أقل من الحد يتجاهل (300 مش في changed)', () => assert.ok(!cmp.changed.some(x => x.code === '300')));
ok('صنف جديد واحد (400)', () => { assert.strictEqual(cmp.added.length, 1); assert.strictEqual(cmp.added[0].code, '400'); });
ok('صنف اختفى واحد (A12)', () => { assert.strictEqual(cmp.removed.length, 1); assert.strictEqual(cmp.removed[0].code, 'A12'); });
ok('baseline=true لما فيه مرجع', () => assert.strictEqual(cmp.baseline, true));

const cmpEx = compare(oldSnap, newSnap, { threshold: 0.01, exclusions: [{ code: '100' }] });
ok('الاستثناء يخفي الكود من changed', () => assert.strictEqual(cmpEx.changed.length, 0));

const cmpFirst = compare(null, newSnap, { threshold: 0.01, exclusions: [] });
ok('أول كشف: كله added و baseline=false', () => { assert.strictEqual(cmpFirst.added.length, 4); assert.strictEqual(cmpFirst.baseline, false); });

console.log(`\n${pass} تأكيد نجح` + (process.exitCode ? ' — فيه فشل ☝️' : ' — كله تمام ✅'));
