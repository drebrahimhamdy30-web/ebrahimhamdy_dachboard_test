#!/usr/bin/env node
/* smoke-screen.js — بيشغّل سكربت الشاشة في بيئة وهمية ويمسك أخطاء
   **وقت التشغيل**، مش الصياغة بس.

   السبب: فحص new Function() بيقول «الصياغة سليمة» على كود بيقع أول ما
   يشتغل. حصل 2026-10-21: تعليق // في آخر سطر مُدرَج بلع باقي السطر،
   فـEXCL_READY مااتسندتش، وinit وقع بـ«Cannot read properties of null
   (reading then)» والشاشة فضلت «جار التحميل». الصياغة كانت سليمة.

   الاستعمال:  node scripts/smoke-screen.js medicine_orders.html
*/
/* بيحمّل سكربت الشاشة كامل في بيئة وهمية ويشغّل الـIIFE بتاع init
   — الهدف نمسك أخطاء وقت التشغيل زي اللي حصلت، مش الصياغة بس. */
const fs = require('fs');
const FILE = process.argv[2] || 'medicine_orders.html';
const s = fs.readFileSync(FILE, 'utf8');
const blocks = [...s.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const main = blocks.reduce((a, b) => b.length > a.length ? b : a, '');

const ids = new Set([...s.matchAll(/id="([^"]+)"/g)].map(m => m[1]));
const el = () => {
  const o = { style:{}, classList:{ add(){}, remove(){}, toggle(){}, contains(){return false} },
    dataset:{}, value:'', textContent:'', innerHTML:'', checked:false, disabled:false, options:[],
    addEventListener(){}, appendChild(){}, setAttribute(){}, getAttribute(){return null},
    querySelector(){return null}, querySelectorAll(){return []}, closest(){return null},
    insertAdjacentHTML(){}, focus(){}, select(){}, click(){}, remove(){} };
  return o;
};
const store = {};
global.document = {
  getElementById: id => ids.has(id) ? (store[id] ||= el()) : null,
  querySelector: () => null, querySelectorAll: () => [],
  addEventListener(){}, createElement: el, body: el(), documentElement: el()
};
global.window = { addEventListener(){}, location:{ href:'', search:'' }, matchMedia:()=>({matches:false,addEventListener(){}}) };
global.location = { href:'http://x/medicine_orders.html', search:'', origin:'http://x', pathname:'/medicine_orders.html' };
global.navigator = { clipboard:{ writeText:async()=>{} }, userAgent:'node' };
global.localStorage = { getItem:()=>null, setItem(){}, removeItem(){} };
global.fetch = () => Promise.resolve({ ok:true, status:200, json:()=>Promise.resolve([]), text:()=>Promise.resolve('[]'), headers:{ get:()=>null } });
global.Session = { role:()=>'admin', bearer:async()=>'t', seesAllBranches:()=>true, branch:()=>'المعمورة', getAll:async()=>[], user:()=>({}) };
global.Branches = { all:()=>[{name:'المعمورة'},{name:'سان ستيفانو'},{name:'سيدى بشر'},{name:'السيوف'}],
  codeMap:()=>({mamora:'المعمورة',san:'سان ستيفانو',bishr:'سيدى بشر',seyouf:'السيوف'}),
  keys:()=>['mamora','san','bishr','seyouf'], names:()=>['المعمورة','سان ستيفانو','سيدى بشر','السيوف'],
  nameOf:c=>c, codeOf:n=>n, ready:async()=>{} };
global.XLSX = { utils:{}, writeFile(){} };
global.SB_URL_API = 'http://x'; global.SB_ANON_API = 'k'; global.PHALIX_CONFIG = { supabaseUrl:'http://x' };
global.sbH = async () => ({}); global.sbTaskInsert = async () => ({ok:true}); global.sbFailMsg = m => m;
global.alert = () => {}; global.confirm = () => false;

let failed = null;
process.on('unhandledRejection', e => { failed = e; });
try { new Function(main)(); }
catch (e) { console.log('✗ وقع وقت التشغيل:', e.message); process.exit(1); }
setTimeout(() => {
  if (failed) { console.log('✗ promise مرفوض:', failed.message); process.exit(1); }
  console.log('✓ ' + FILE + ' — اشتغل من غير أخطاء وقت التشغيل');
}, 300);
