import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   نسخة احتياطية على دفعات — بذاكرة محدودة
   ═══════════════════════════════════════════════════════════════════
   النسخة القديمة كانت بتعمل حاجتين بيقتلوا الذاكرة:
     1. بتحمّل كل جدول **كامل** في مصفوفة JS (sales_items لوحده 108MB
        خام، يبقى أضعافها كـobjects في الذاكرة).
     2. بتبني أرشيف للقاعدة كلها في بَفَر واحد عشان ترفعه على Drive.
   القاعدة بقت ~400MB، فالدالة كانت بتقع بـWORKER_RESOURCE_LIMIT —
   وواقفة من 28 يوليو من غير ما حد ياخد باله، لأن الـcron بيقول «نجح»
   (net.http_post بيرجّع فورًا: النجاح ده للإرسال مش للنتيجة).

   الجديد:
     • كل نداء بيشتغل ~50 ثانية ويسيب مكانه في backup_runs، والـcron
       بيكمّل. الذاكرة محدودة بصفحة واحدة (500 صف) مهما كبرت القاعدة.
     • كل صفحة بتترفع كملف مستقل: folder/table/part-0001.json.gz
     • مفيش أرشيف مجمّع في الذاكرة خالص.

   ⚠️ التوكن مايتكتبش في الكود — الريبو ده عام. مخزّن في vault.
   ═══════════════════════════════════════════════════════════════════ */

const BUCKET = "db-backups";
const KEEP_LAST = 30;
const PAGE = 1000;             // صفوف لكل دفعة
const MAX_PARTS_PER_RUN = 30;  // سقف الشغل في النداء الواحد
const SAVE_EVERY = 10;         // نحفظ المكان كل كام جزء
const BUDGET_MS = 25_000;      // هامش قبل حد وقت التنفيذ

let _tokCache: { v: string; exp: number } | null = null;
async function triggerToken(admin: any): Promise<string> {
  const now = Date.now();
  if (_tokCache && _tokCache.exp > now) return _tokCache.v;
  // سكيما vault مش معروضة لـPostgREST، فبنعدّي على دالة وسيطة
  // (public.vault_secret) صلاحيتها لـservice_role بس.
  const { data } = await admin.rpc("vault_secret", { p_name: "backup_trigger_token" });
  const v = typeof data === "string" ? data : "";
  _tokCache = { v, exp: now + 60_000 };
  return v;
}

async function gzipBytes(bytes: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream("gzip");
  const w = cs.writable.getWriter();
  w.write(bytes); w.close();
  return new Uint8Array(await new Response(cs.readable).arrayBuffer());
}

function stampNow(): string {
  return new Date().toISOString().slice(0, 19).replace(/[:]/g, "").replace(/-/g, "");
}

function pad(n: number, w = 4): string { return String(n).padStart(w, "0"); }

Deno.serve(async (req: Request) => {
  const started = Date.now();
  const url = new URL(req.url);
  const token = url.searchParams.get("token") || req.headers.get("x-backup-token") || "";

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  // التوكن من vault. فاضي = رفض — عشان لو السر اتمسح مايبقاش مفتوح للكل.
  const expected = await triggerToken(admin);
  if (!expected || token !== expected) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

  // ── 1) نكمّل تشغيلة شغّالة، وإلا نبدأ واحدة جديدة ──────────────────
  const { data: running } = await admin.from("backup_runs")
    .select("*").eq("status", "running").order("id", { ascending: false }).limit(1).maybeSingle();

  let run = running;

  if (!run) {
    // ?resume=1 معناها «كمّل بس» — الـcron بيستعمله كل دقيقة عشان
    // مايبدأش نسخة جديدة؛ البداية اليومية ليها نداء منفصل.
    if (url.searchParams.get("resume") === "1") return json({ ok: true, idle: true });

    const { data: tbls, error: tErr } = await admin.rpc("list_public_tables");
    if (tErr) return json({ error: "list_tables: " + tErr.message }, 500);
    const tables = (tbls as unknown[]).map(String).sort();

    const { data: created, error: cErr } = await admin.from("backup_runs")
      .insert({ folder: `backup-${stampNow()}`, tables, page_size: PAGE }).select().single();
    if (cErr) return json({ error: "create_run: " + cErr.message }, 500);
    run = created;
  }

  // ── 2) نشتغل لحد ما الوقت يخلص ──────────────────────────────────
  let ti: number = run.tbl_index;
  let page: number = run.page;
  let rowsDone: number = run.rows_done;
  let partsDone: number = run.parts_done;
  const tables: string[] = run.tables;
  const folder: string = run.folder;
  let lastError: string | null = run.last_error ?? null;

  // ⚠️ بنستعمل حجم الصفحة المحفوظ مع التشغيلة مش الثابت الحالي.
  // لو الثابت اتغيّر بعد ما التشغيلة بدأت، الاستئناف بالحجم الجديد
  // بيقرا من مكان غلط ويسيب فجوة في الجدول — حصل فعلًا مع order_logs.
  const pageSize: number = run.page_size ?? PAGE;

  // ⚠️ الحفظ لازم يكون **دوري** مش في الآخر بس. لو الدالة وقعت
  // بـWORKER_RESOURCE_LIMIT قبل ما تحفظ، التقدّم بيضيع والنداء اللي بعده
  // يعيد نفس الشغل ويقع تاني — حلقة لا نهائية. حصل فعلًا عند order_logs.
  const save = async (finished: boolean) =>
    await admin.from("backup_runs").update({
      tbl_index: ti, page, rows_done: rowsDone, parts_done: partsDone,
      last_error: lastError, updated_at: new Date().toISOString(),
      ...(finished ? { status: "done", finished_at: new Date().toISOString() } : {}),
    }).eq("id", run.id);

  let partsThisRun = 0;

  while (ti < tables.length
         && Date.now() - started < BUDGET_MS
         && partsThisRun < MAX_PARTS_PER_RUN) {
    const t = tables[ti];
    const from = page * pageSize;

    const { data, error } = await admin.from(t).select("*").range(from, from + pageSize - 1);

    if (error) {
      // جدول مش مقروء (view أو صلاحية) — نسجّله ونعدّي بدل ما نقف
      lastError = `${t}: ${error.message}`;
      ti++; page = 0;
      await save(false);
      continue;
    }

    const rows = data ?? [];
    if (rows.length > 0) {
      const gz = await gzipBytes(new TextEncoder().encode(JSON.stringify(rows)));
      const { error: upErr } = await admin.storage.from(BUCKET)
        .upload(`${folder}/${t}/part-${pad(page + 1)}.json.gz`, gz,
                { contentType: "application/gzip", upsert: true });
      if (upErr) lastError = `${t} upload: ${upErr.message}`;
      rowsDone += rows.length;
      partsDone++;
      partsThisRun++;
    }

    if (rows.length < pageSize) { ti++; page = 0; }   // الجدول خلص
    else { page++; }

    if (partsThisRun % SAVE_EVERY === 0) await save(false);
  }

  const done = ti >= tables.length;

  // ── 3) نحفظ المكان ─────────────────────────────────────────────
  await save(done);

  if (!done) {
    return json({ ok: true, done: false, folder, progress: `${ti}/${tables.length}`,
                  table: tables[ti], page, rows: rowsDone, parts: partsDone });
  }

  // ── 4) خلصت: manifest + تنظيف النسخ القديمة ────────────────────
  const manifest = {
    created_at: new Date().toISOString(), bucket: BUCKET, folder,
    tables: tables.length, total_rows: rowsDone, parts: partsDone,
    last_error: lastError, format: "per-table pages: <table>/part-NNNN.json.gz",
  };
  await admin.storage.from(BUCKET).upload(`${folder}/_manifest.json`,
    new Blob([JSON.stringify(manifest, null, 2)], { type: "application/json" }), { upsert: true });

  const deleted: string[] = [];
  const { data: roots } = await admin.storage.from(BUCKET)
    .list("", { limit: 1000, sortBy: { column: "name", order: "asc" } });
  const folders = (roots || []).filter((r) => r.name.startsWith("backup-")).map((r) => r.name).sort();
  if (folders.length > KEEP_LAST) {
    for (const f of folders.slice(0, folders.length - KEEP_LAST)) {
      // النسخ الجديدة فيها مجلد لكل جدول، فالحذف على مستويين
      const { data: subs } = await admin.storage.from(BUCKET).list(f, { limit: 1000 });
      for (const s of subs || []) {
        const { data: files } = await admin.storage.from(BUCKET).list(`${f}/${s.name}`, { limit: 1000 });
        const paths = (files || []).map((x) => `${f}/${s.name}/${x.name}`);
        if (paths.length) await admin.storage.from(BUCKET).remove(paths);
      }
      const { data: top } = await admin.storage.from(BUCKET).list(f, { limit: 1000 });
      const topPaths = (top || []).map((x) => `${f}/${x.name}`);
      if (topPaths.length) await admin.storage.from(BUCKET).remove(topPaths);
      deleted.push(f);
    }
  }

  return json({ ok: true, done: true, folder, tables: tables.length,
                total_rows: rowsDone, parts: partsDone, deleted_old: deleted.length,
                last_error: lastError });
});
