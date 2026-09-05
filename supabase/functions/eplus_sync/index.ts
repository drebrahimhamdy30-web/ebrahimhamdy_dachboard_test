import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   مزامنة eplus — محرّك النقاط المجدولة في شاشة «الربط بالمصادر»
   ═══════════════════════════════════════════════════════════════════
   بيقرا `integration_endpoints`، ينفّذ اللي حان وقته، يسجّل في
   `integration_data`، ويرفع النتيجة للجدول الهدف حسب `field_map`.

   ⚠️ **بتضرب نظام eplus الحقيقي.** على سيرفر التجربة **ماتشغّلش
      الـcron بتاعها** (`eplus_sync_tick`) — هتبقى مزامنة مكرّرة على
      نفس نظام eplus اللي الإنتاج شغّال عليه، وممكن تكتب بيانات
      متضاربة كمان.

   ⚠️ المصادقة: مفتاح cron (`x-sync-key` = متغيّر البيئة `SYNC_KEY`)
      أو توكن موظف بدور مسموح. `!!SYNC_KEY` في الشرط معناها إن السر
      الفاضي = **رفض** مش سماح للكل.

   ⚠️ كل حسابات الوقت بتوقيت **القاهرة** (دوال cf/cairoToEpoch/DT) —
      عشان الجدولة تعكس الوقت المحلي الحقيقي مش UTC.
      ماتستبدلهاش بـDate عادي.

   ⚠️ بيانات الدخول من `EPLUS_BRANCHES` (متغيّر بيئة):
      {"اسم الفرع": {"base":"https://...","basic":"user:pass"}}
   ═══════════════════════════════════════════════════════════════════ */

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-sync-key", "Access-Control-Allow-Methods": "POST, OPTIONS" };
function jsonRes(b: unknown, s = 200) { return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } }); }
function claimFromJwt(auth: string): any { try { const t = auth.replace(/^Bearer\s+/i, ""); return JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); } catch { return null; } }
const ADMIN_ROLES = ["admin", "manager", "inventory", "pharmacist"];
function roleOf(claims: any) { return String(claims?.user_role ?? claims?.app_role ?? ""); }

// ── حساب الوقت بتوقيت القاهرة (مش UTC ومش توقيت السيرفر) ────────
function cf(ms: number) { const s = new Date(ms).toLocaleString("en-GB", { timeZone: "Africa/Cairo", hour12: false }); const [dm, tm] = s.split(", "); const [d, mo, y] = dm.split("/"); const [H, Mi, S] = tm.split(":"); return { y, mo, d, H, Mi, S }; }
function cairoOffset(ms: number) { const f = cf(ms); return Date.UTC(+f.y, +f.mo - 1, +f.d, +f.H, +f.Mi, +f.S) - ms; }
function cairoToEpoch(y: number, mo: number, d: number, H: number, Mi: number, S: number) { const g = Date.UTC(y, mo - 1, d, H, Mi, S); return g - cairoOffset(g); }
function durMs(o: Record<string, number>) { const u: Record<string, number> = { year: 31557600000, years: 31557600000, month: 2629800000, months: 2629800000, week: 604800000, weeks: 604800000, day: 86400000, days: 86400000, hour: 3600000, hours: 3600000, minute: 60000, minutes: 60000, second: 1000, seconds: 1000 }; let ms = 0; for (const k in (o || {})) ms += (Number(o[k]) || 0) * (u[k] || 0); return ms; }
function DT(ms: number) { return { ms, minus(o: Record<string, number>) { return DT(ms - durMs(o)); }, plus(o: Record<string, number>) { return DT(ms + durMs(o)); }, startOf(u: string) { const f = cf(ms); if (u === "day") return DT(cairoToEpoch(+f.y, +f.mo, +f.d, 0, 0, 0)); if (u === "month") return DT(cairoToEpoch(+f.y, +f.mo, 1, 0, 0, 0)); return DT(ms); }, endOf(u: string) { const f = cf(ms); if (u === "day") return DT(cairoToEpoch(+f.y, +f.mo, +f.d, 23, 59, 59)); return DT(ms); }, format(pat: string) { const f = cf(ms); return String(pat || "yyyy-MM-dd HH:mm:ss").replace(/yyyy/g, f.y).replace(/MM/g, f.mo).replace(/dd/g, f.d).replace(/HH/g, f.H).replace(/mm/g, f.Mi).replace(/ss/g, f.S); }, toString() { return this.format("yyyy-MM-dd HH:mm:ss"); } }; }

// ── قوالب {{ $today.minus({days:1}).format('yyyy-MM-dd') }} ─────
function stripQ(s: string) { return s.trim().replace(/^['"]|['"]$/g, ""); }
function parseObj(s: string) { try { return JSON.parse(s.replace(/(\w+)\s*:/g, '"$1":').replace(/'/g, '"')); } catch { return {}; } }
function evalInner(inner: string, ctx: { branch: string }): string { inner = inner.trim(); const m = inner.match(/^\$(now|today|branch)/); if (!m) return inner; if (m[1] === "branch") return ctx.branch || ""; let cur: any = m[1] === "today" ? DT(Date.now()).startOf("day") : DT(Date.now()); let rest = inner.slice(m[0].length); const re = /^\.(\w+)\(([^)]*)\)/; let g; while ((g = rest.match(re))) { const fn = g[1], arg = g[2].trim(); if (fn === "format") return cur.format(stripQ(arg)); if (fn === "minus" || fn === "plus") cur = cur[fn](parseObj(arg)); else if (fn === "startOf" || fn === "endOf") cur = cur[fn](stripQ(arg)); rest = rest.slice(g[0].length); } return cur.toString(); }
function resolveTpl(tmpl: string, ctx: { branch: string }) { return String(tmpl).replace(/\{\{([\s\S]*?)\}\}/g, (_m, i) => { try { return evalInner(i.trim(), ctx); } catch { return "{{ERR}}"; } }); }

function nextDaily(hhmm: string) { const p = String(hhmm).split(":"); const h = Number(p[0]) || 0, mi = Number(p[1]) || 0; const f = cf(Date.now()); let ep = cairoToEpoch(+f.y, +f.mo, +f.d, h, mi, 0); if (ep <= Date.now()) ep += 86400000; return ep; }
function nextRunSuccess(e: any, now: number): string | null { if (!e.sched_enabled) return null; if (e.daily_at) return new Date(nextDaily(e.daily_at)).toISOString(); if (e.interval_minutes) return new Date(now + e.interval_minutes * 60000).toISOString(); return null; }

async function callEplus(cfg: any, ep: any, params: any[], body: string | null) {
  const authHeader = "Basic " + (String(cfg.basic).includes(":") ? btoa(cfg.basic) : cfg.basic);
  const method = String(ep.method || "GET").toUpperCase();
  const usp = new URLSearchParams();
  (params || []).forEach((p) => { if (p && p.enabled !== false && p.key) usp.append(p.key, p.value ?? ""); });
  const qs = usp.toString();
  const url = String(cfg.base).replace(/\/$/, "") + ep.path + (method === "GET" && qs ? "?" + qs : "");
  const opts: RequestInit = { method, headers: { Authorization: authHeader, Accept: "application/json" }, redirect: "follow" };
  if (method !== "GET") { (opts.headers as any)["Content-Type"] = "application/json"; opts.body = body || (qs ? JSON.stringify(Object.fromEntries(usp)) : "{}"); }
  const r = await fetch(url, opts); const text = await r.text();
  let all: number | null = null, ret: number | null = null, full: any[] = [], preview: unknown = null;
  try { const j = JSON.parse(text); all = j.AllRecords ?? null; if (Array.isArray(j.Data)) { ret = j.Data.length; full = j.Data.slice(0, 5000); preview = j.Data.slice(0, 100); } else preview = j; } catch { preview = text.slice(0, 5000); }
  return { ok: r.ok, status: r.status, all_records: all, returned: ret, full, preview };
}

async function upsertDest(supa: any, ep: any, rowsRaw: any[], branch: string) {
  if (!ep.dest_table || !Array.isArray(ep.field_map) || !ep.field_map.length) return { done: false, count: 0 };
  const rows = (rowsRaw || []).map((r) => { const o: any = {}; for (const fm of ep.field_map) { if (fm && fm.dst) { let v = r[fm.src]; if (v === "" || v === undefined) v = null; o[fm.dst] = v; } } if (ep.dest_add_branch) o.branch = branch; return o; });
  if (!rows.length) return { done: true, count: 0 };
  const onConflict = ep.dest_key ? String(ep.dest_key).replace(/\s+/g, "") : undefined;
  let count = 0;
  for (let i = 0; i < rows.length; i += 500) { const chunk = rows.slice(i, i + 500); const { error } = await supa.from(ep.dest_table).upsert(chunk, onConflict ? { onConflict } : {}); if (error) throw new Error(error.message); count += chunk.length; }
  return { done: true, count };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const SYNC_KEY = Deno.env.get("SYNC_KEY");
  const isCron = !!SYNC_KEY && (req.headers.get("x-sync-key") || "") === SYNC_KEY;
  const claims = claimFromJwt(req.headers.get("Authorization") || "");
  const isAdmin = !!claims && ADMIN_ROLES.includes(roleOf(claims));
  if (!isCron && !isAdmin) return jsonRes({ ok: false, error: "unauthorized" }, 403);

  const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let bmap: Record<string, { base: string; basic: string }> = {};
  try { bmap = JSON.parse(Deno.env.get("EPLUS_BRANCHES") || "{}"); } catch { /* */ }
  const branchKeys = Object.keys(bmap);
  if (!branchKeys.length) return jsonRes({ ok: false, error: "secret_not_set", hint: "اضبط EPLUS_BRANCHES" }, 500);

  let force: number | null = null;
  try { const b = await req.json(); if (b && b.endpoint_id) force = Number(b.endpoint_id); } catch { /* */ }

  const nowIso = new Date().toISOString();
  let q = supa.from("integration_endpoints").select("*");
  if (force) q = q.eq("id", force);
  else q = q.eq("sched_enabled", true).or(`next_run_at.is.null,next_run_at.lte.${nowIso}`);
  const { data: eps } = await q;

  const results: any[] = [];
  for (const e of (eps || [])) {
    const branches = e.run_branches ? branchKeys : [branchKeys[0]].filter(Boolean);
    let anyFail = false, lastErr = "", upserted = 0;
    for (const br of branches) {
      const cfg = bmap[br];
      if (!cfg) { anyFail = true; lastErr = "branch_not_configured:" + br; await supa.from("integration_data").insert({ endpoint_id: e.id, endpoint_name: e.name, branch: br, ok: false, error: lastErr }); continue; }
      const rparams = (e.params || []).map((p: any) => ({ key: p.key, enabled: p.enabled, value: p.mode === "expr" ? resolveTpl(p.value, { branch: br }) : p.value }));
      const rbody = e.body ? resolveTpl(e.body, { branch: br }) : null;
      try {
        const res = await callEplus(cfg, e, rparams, rbody);
        await supa.from("integration_data").insert({ endpoint_id: e.id, endpoint_name: e.name, branch: br, ok: res.ok, status: res.status, all_records: res.all_records, returned: res.returned, data: res.preview, error: res.ok ? null : ("status " + res.status) });
        if (!res.ok) { anyFail = true; lastErr = "status " + res.status; }
        else { const u = await upsertDest(supa, e, res.full, br); if (u.done) upserted += (u.count || 0); }
      } catch (err) { anyFail = true; lastErr = String((err as Error)?.message || err); await supa.from("integration_data").insert({ endpoint_id: e.id, endpoint_name: e.name, branch: br, ok: false, error: lastErr }); }
    }
    // فشل = إعادة محاولة بعد retry_minutes؛ نجاح = الموعد الجاي حسب الجدولة
    const now = Date.now();
    const patch = anyFail
      ? { last_run_at: new Date(now).toISOString(), last_status: "failed", last_error: lastErr, fail_count: (e.fail_count || 0) + 1, next_run_at: e.sched_enabled ? new Date(now + (e.retry_minutes || 5) * 60000).toISOString() : e.next_run_at }
      : { last_run_at: new Date(now).toISOString(), last_status: "success", last_error: null, fail_count: 0, next_run_at: nextRunSuccess(e, now) };
    await supa.from("integration_endpoints").update(patch).eq("id", e.id);
    results.push({ id: e.id, name: e.name, status: anyFail ? "failed" : "success", upserted, error: anyFail ? lastErr : null, next_run_at: patch.next_run_at });
  }
  return jsonRes({ ok: true, processed: results.length, results });
});
