#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   حارس سقف الـ1000 صف — بيمنع رجوع الفخ مع أي شاشة جديدة
   ═══════════════════════════════════════════════════════════════════
   PostgREST بيقص أي رد عند 1000 صف (db-max-rows)، والقص بيحصل **بعد**
   الفلترة والترتيب. يعني الشاشة بتاخد «أحدث 1000»، تحسب عليهم إجمالي،
   وتعرضه كأنه صح — من غير أي خطأ. الحارس ده بيمسك الأنماط اللي بتوصّل
   للحالة دي قبل ما الكود يتدفع.

   بيمسك:
     ① نداء على جدول كبير من غير ترقيم ولا فلتر ضيق  → غالبًا بيتقص
     ② limit أكبر من 1000 (وهم — بيرجع 1000 بالظبط)
     ③ .limit(N>1000) في supabase-js
     ④ نداء لدالة RPC بترجّع صفوف من غير ترقيم
     ⑤ .from(...).select(...) في supabase-js من غير تضييق ولا ترقيم

   الاستثناء: تعليق على نفس السطر:  // data-ok: السبب

   الاستعمال:
     node scripts/check-fetch-limits.js
     node scripts/check-fetch-limits.js --list    # يطبع كل النداءات اللي شافها
   بيرجّع كود 1 لو لقى مشاكل — ينفع في hook أو CI.
   ═══════════════════════════════════════════════════════════════════ */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const LIST = process.argv.includes('--list');
const WINDOW = 5;        // الاستعلام ممكن يتكتب على أكتر من سطر (.range بعد .order مثلًا)

/* دوال RPC اللي بترجّع **صفوف** (setof/table) — بتتقص زي الجداول بالظبط.
   للتحديث:
     select string_agg(proname,',' order by proname) from pg_proc p
       join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proretset;                        */
const SETOF_RPCS = new Set(['audit_branch_values','best_store_for','branch_letters','delivery_active_days',
  'delivery_by_hour','difficult_driver_load','get_all_branch_users','get_closure_machine_recon',
  'get_closure_machine_txns','get_completed_orders_for_bills','get_consumption_rates','get_contract_returns',
  'get_cs_orders','get_customer_names','get_driver_daily_report','get_driver_emails','get_driver_hard_trips_today',
  'get_driver_month_stats','get_driver_rank','get_driver_shift_report','get_hard_load','get_hard_trips_month',
  'get_hard_trips_today','get_idle_with_taken','get_jard_daily_stats','get_jard_efficiency','get_late_returns',
  'get_open_review_flags','get_pos_balances_at','get_prev_trip_orders','get_purchase_companies','get_purchase_orders',
  'get_role_tabs','get_shortages','get_stock_limits','get_taken_off_report','get_trip_counts','get_trip_review_flags',
  'get_unclosed_orders','list_sales_months','price_check_lookup','quick_search_stock','report_conflicting_codes',
  'report_delivered_trip_completed','report_shared_codes','sales_active_days','sales_by_day','sales_by_employee',
  'sales_by_hour','sales_detail','sales_discount_bills','sales_discount_stats','sales_overview','sales_price_review',
  'sales_summary','sales_top_items','suggest_codes_for_names','suggest_contract_invoices','suggest_purchase_sources',
  'suggest_stock_codes']);

/* جداول صغيرة/ثابتة — قراءتها كاملة مقبولة (كلها أقل من ~200 صف وبتكبر ببطء) */
const SMALL_TABLES = new Set(['branches','regions','routes','route_regions','region_names','stores','app_pages',
  'page_permissions','app_page_tabs','tab_permissions','org_settings','dispatch_settings','pos_methods',
  'purchase_settings','bank_settings','integration_endpoints','integration_branch_stores','branch_stores',
  'instructions','demand_tiers','jard_excluded_codes','order_transfer_pending','order_store_override',
  'store_sheet_mappings','claims','drivers','driver_breaks','task_assignee','task_done','archived_items',
  'code_replace','consumption_exceptional','sales_analysis_access','branch_users','jard_committee','problems',
  'gift_campaigns','supplier_balance_settings','supplier_balance_runs','supplier_balance_exclusions',
  'driver_app_version','known_item_codes','stock_limit','monthly_sales_months','pos_branch_opening',
  'contracts','missing_items','material_prices','offers','cosmo_states','overstock_exclusions','tasks',
  'v_branch_value_audit','erp_expense_hide_rules','supplier_movement_reviews','supplier_balance_notes',
  'pos_manual_transfers','pos_wallet_transfers','pos_period_closes','cash_to_wallet','links','sales_months']);

const NARROWING = /(=eq\.|=in\.\(|=gte\.|=lte\.|=gt\.|=lt\.|=is\.|=ilike\.|=like\.|=cs\.|=ov\.|=neq\.|=not\.)/;
const PAGED     = /(limit=|offset=|Session\.getAll|Session\.rpcAll|sbGetAll|fetchAllPaged|\.range\()/;
const WRITE     = /(method\s*:\s*['"`](POST|PATCH|DELETE|PUT)|\.(insert|update|upsert|delete)\()/;

const findings = [];
const seen = [];

function scanFile(file) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  if (/^(scripts|docs|node_modules|\.git)\//.test(rel)) return;
  const raw = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const lines = raw.split('\n');

  // ① خريطة الثوابت: const SB_X_URL = `${...}/rest/v1/table`
  const consts = {};
  lines.forEach(l => {
    const m = l.match(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=.*rest\/v1\/([a-z_][a-z0-9_]*)\s*[`'"]/);
    if (m && m[2] !== 'rpc') consts[m[1]] = m[2];
  });
  const constNames = Object.keys(consts);

  let inBlock = false;   // جوّه /* … */ — التعليقات اللي بتشرح الفخ مش نداءات
  lines.forEach((line, i) => {
    const wasInBlock = inBlock;
    const opens = (line.split('/*').length - 1), closes = (line.split('*/').length - 1);
    if (opens > closes) inBlock = true; else if (closes > opens) inBlock = false;
    if (wasInBlock) return;
    if (/\/\/\s*data-ok:/.test(line)) return;
    // سطر تعليق مش نداء — من غير كده التعليقات اللي بتشرح الفخ نفسه بتترصد
    const bare = line.trim();
    if (!bare || bare.startsWith('//') || bare.startsWith('*') || bare.startsWith('/*') ||
        bare.startsWith('<!--') || bare.startsWith('--')) return;
    const at = rel + ':' + (i + 1);
    const ctx = lines.slice(i, i + WINDOW).join(' ');        // الاستعلام ممكن يكمل تحت
    const isWrite = WRITE.test(ctx) && !/Session\.rpcAll/.test(ctx);

    // ② limit أكبر من السقف = وهم
    const big = line.match(/limit=(\d{4,})/) || line.match(/\.limit\((\d{4,})\)/);
    if (big && +big[1] > 1000) {
      findings.push([at, 'limit=' + big[1] + ' وهم — PostgREST بيرجّع 1000 بالظبط', line.trim()]);
    }

    // ③ تحديد الجدول/الدالة اللي بيتنادى عليها في السطر ده
    let table = null, isRpc = false;
    let m;
    if ((m = line.match(/rest\/v1\/rpc\/([a-z_][a-z0-9_]*)/))) { table = m[1]; isRpc = true; }
    else if ((m = line.match(/rest\/v1\/([a-z_][a-z0-9_]*)\?/)))  { table = m[1]; }
    else if ((m = line.match(/\b(?:REST|SB_REST|api|sbGet)\s*(?:\+\s*)?[('`"]\s*\+?\s*['"`]?([a-z_][a-z0-9_]*)\?/))) { table = m[1]; }
    else {
      for (const c of constNames) {
        if (line.indexOf(c) >= 0 && /fetch\s*\(/.test(line)) { table = consts[c]; break; }
      }
    }

    if (table && !isWrite) {
      seen.push([at, (isRpc ? 'rpc/' : '') + table]);
      const paged = PAGED.test(ctx);
      if (isRpc) {
        if (SETOF_RPCS.has(table) && !paged) {
          findings.push([at, 'دالة «' + table + '» بترجّع صفوف من غير ترقيم — هتتقص عند 1000', line.trim()]);
        }
      } else if (!SMALL_TABLES.has(table) && !paged && !NARROWING.test(ctx)) {
        findings.push([at, 'جدول «' + table + '» بيتقرا من غير ترقيم ولا فلتر ضيق', line.trim()]);
      }
    }

    // ④ supabase-js
    const f = line.match(/\.from\(['"]([a-z_][a-z0-9_]*)['"]\)/);
    if (f && /\.select\(/.test(ctx) && !WRITE.test(line)) {
      const name = f[1];
      seen.push([at, name + ' (supabase-js)']);
      const narrowed = /\.(eq|in|gte|lte|gt|lt|is|like|ilike|contains|match|single|maybeSingle|range|limit|textSearch|or)\(/.test(ctx);
      if (!SMALL_TABLES.has(name) && !narrowed) {
        findings.push([at, 'جدول «' + name + '» (supabase-js) من غير تضييق ولا ترقيم', line.trim()]);
      }
    }
  });
}

function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.git' || e.name === 'node_modules') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (/\.(html|js)$/.test(e.name)) scanFile(p);
  }
}

walk(ROOT);

if (LIST) {
  console.log('النداءات اللي اتفحصت (' + seen.length + '):');
  seen.forEach(([at, what]) => console.log('  ' + at + '  ' + what));
  console.log('');
}

if (!findings.length) {
  console.log('✅ مفيش نداء معرّض للقص عند 1000 صف (' + seen.length + ' نداء اتفحص)');
  process.exit(0);
}

console.log('⚠️ ' + findings.length + ' نداء معرّض للقص عند سقف 1000 صف:\n');
findings.forEach(([at, why, code]) => {
  console.log('  ' + at + '\n     ' + why + '\n     ' + code.slice(0, 140));
});
console.log('\nالحل: Session.getAll(path) للجداول · Session.rpcAll(fn,body) للدوال اللي بترجّع صفوف،');
console.log('أو فلتر ضيق يوصل للسيرفر (eq/in/gte على فرع أو تاريخ).');
console.log('ولو النداء آمن فعلًا حطّ على السطر:  // data-ok: السبب');
process.exit(1);
