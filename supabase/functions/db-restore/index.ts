import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   استرجاع نسخة احتياطية — أخطر دالة في النظام
   ═══════════════════════════════════════════════════════════════════
   ⚠️ النسخة القديمة كان فيها التوكن **مكتوب صريح**، وهو **نفس التوكن
      اللي اتسرّب على GitHub** (الريبو عام). يعني أي حد قرا تاريخ الريبو
      كان يقدر ينده الدالة دي ويكتب فوق قاعدة البيانات كلها بنسخة قديمة.
      db-backup اتصلّح وقتها لكن الدالة دي فضلت شايلة نسخة من التوكن
      القديم — الدرس: لما تدوّر سر، دوّر على **كل** نسخة منه مش اللي
      لقيتها بس.

   دلوقتي: التوكن من vault (نفس اللي بيستعمله db-backup بعد التدوير)،
   وفاضي = رفض مش سماح.
   ═══════════════════════════════════════════════════════════════════ */

const BUCKET = "db-backups";

let _tok: { v: string; exp: number } | null = null;
async function triggerToken(admin: any): Promise<string> {
  const now = Date.now();
  if (_tok && _tok.exp > now) return _tok.v;
  // سكيما vault مش معروضة لـPostgREST — بنعدّي على دالة وسيطة
  // صلاحيتها لـservice_role بس.
  const { data } = await admin.rpc("vault_secret", { p_name: "backup_trigger_token" });
  const v = typeof data === "string" ? data : "";
  _tok = { v, exp: now + 60_000 };
  return v;
}

async function gunzipToText(blob: Blob): Promise<string> {
  const ds = new DecompressionStream("gzip");
  const stream = blob.stream().pipeThrough(ds);
  return await new Response(stream).text();
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const token = url.searchParams.get("token") || req.headers.get("x-backup-token") || "";

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  // سر فاضي = رفض. لو السر اتمسح من vault الدالة تتقفل، مش تتفتح للكل.
  const expected = await triggerToken(admin);
  if (!expected || token !== expected) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  const mode = (url.searchParams.get("mode") || "upsert").toLowerCase();
  const tablesParam = url.searchParams.get("tables") || "all";
  const dryRun = url.searchParams.get("dry_run") === "1";
  let folder = url.searchParams.get("folder") || "";

  // لو مفيش folder: خد أحدث نسخة
  if (!folder) {
    const { data: roots } = await admin.storage.from(BUCKET).list("", { limit: 1000 });
    const fs = (roots || []).filter((r) => r.name.startsWith("backup-")).map((r) => r.name).sort();
    folder = fs[fs.length - 1] || "";
  }
  if (!folder) return new Response(JSON.stringify({ error: "no backups found" }), { status: 404, headers: { "Content-Type": "application/json" } });

  const { data: files } = await admin.storage.from(BUCKET).list(folder, { limit: 1000 });
  const availTables = (files || []).filter((f) => f.name.endsWith(".json.gz")).map((f) => f.name.replace(/\.json\.gz$/, ""));

  const wanted = tablesParam === "all" ? availTables : tablesParam.split(",").map((s) => s.trim()).filter(Boolean);

  if (dryRun) {
    return new Response(JSON.stringify({ ok: true, dry_run: true, folder, mode, would_restore: wanted, available: availTables }), { headers: { "Content-Type": "application/json" } });
  }

  const results: unknown[] = [];
  for (const t of wanted) {
    try {
      const { data: blob, error } = await admin.storage.from(BUCKET).download(`${folder}/${t}.json.gz`);
      if (error || !blob) { results.push({ table: t, error: error?.message || "file not found" }); continue; }
      const rows = JSON.parse(await gunzipToText(blob));
      const { data: cnt, error: rErr } = await admin.rpc("restore_table_from_json", { p_table: t, p_rows: rows, p_mode: mode });
      if (rErr) { results.push({ table: t, error: rErr.message }); continue; }
      results.push({ table: t, restored: cnt });
    } catch (e) { results.push({ table: t, error: String(e) }); }
  }

  const failed = results.filter((r) => (r as Record<string, unknown>).error);
  return new Response(JSON.stringify({ ok: failed.length === 0, folder, mode, restored_tables: results.length - failed.length, failed: failed.length, results }), { headers: { "Content-Type": "application/json" } });
});
