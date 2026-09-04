import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// ⚠️ التوكن مايتكتبش في الكود — الريبو ده عام. بييجي من متغيّر بيئة
// (Supabase → Edge Functions → Secrets). التوكن القديم اتكشف على GitHub
// واتغيّر؛ لو رجع تاني في الكود يبقى مكشوف تاني.
const TRIGGER_TOKEN = Deno.env.get("BACKUP_TRIGGER_TOKEN") ?? "";
const BUCKET = "db-backups";
const KEEP_LAST = 30;
const PAGE = 1000;
const BOUNDARY = "phlxBackupBoundary7c1e5b8d";

async function gzipBytes(bytes: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream("gzip");
  const w = cs.writable.getWriter();
  w.write(bytes); w.close();
  return new Uint8Array(await new Response(cs.readable).arrayBuffer());
}

function stampNow(): string {
  const s = new Date().toISOString();
  return s.slice(0, 19).replace(/[:]/g, "").replace(/-/g, "");
}

async function getTokenViaRefresh(clientId: string, clientSecret: string, refreshToken: string): Promise<string> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken, grant_type: "refresh_token" }),
  });
  const j = await res.json();
  if (!j.access_token) throw new Error("oauth_refresh: " + JSON.stringify(j));
  return j.access_token as string;
}

async function driveUpload(token: string, folderId: string, name: string, bytes: Uint8Array): Promise<Record<string, unknown>> {
  const meta = JSON.stringify({ name, parents: [folderId] });
  const pre = `--${BOUNDARY}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n--${BOUNDARY}\r\nContent-Type: application/gzip\r\n\r\n`;
  const post = `\r\n--${BOUNDARY}--`;
  const body = new Blob([pre, bytes, post]);
  const res = await fetch("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,size", {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": `multipart/related; boundary=${BOUNDARY}` }, body,
  });
  return await res.json();
}

async function driveList(token: string, folderId: string): Promise<{ id: string; name: string }[]> {
  const q = encodeURIComponent(`'${folderId}' in parents and trashed=false and name contains '.ndjson.gz'`);
  const res = await fetch(`https://www.googleapis.com/drive/v3/files?q=${q}&fields=files(id,name)&pageSize=1000&orderBy=name`, { headers: { Authorization: `Bearer ${token}` } });
  const j = await res.json();
  return (j.files || []) as { id: string; name: string }[];
}

async function driveDelete(token: string, fileId: string): Promise<void> {
  await fetch(`https://www.googleapis.com/drive/v3/files/${fileId}`, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
}

function cleanFolderId(raw: string): string {
  let id = (raw || "").trim();
  const m = id.match(/folders\/([^/?#]+)/);
  if (m) id = m[1];
  const q = id.indexOf("?"); if (q >= 0) id = id.slice(0, q);
  return id.trim();
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const token = url.searchParams.get("token") || req.headers.get("x-backup-token") || "";
  if (!TRIGGER_TOKEN || token !== TRIGGER_TOKEN) {   // توكن فاضي = ممنوع، مش مسموح للكل
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  const folder = `backup-${stampNow()}`;

  const { data: tbls, error: tErr } = await admin.rpc("list_public_tables");
  if (tErr) return new Response(JSON.stringify({ error: "list_tables: " + tErr.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  const tables: string[] = (tbls as unknown[]).map((x) => String(x));

  const cs = new CompressionStream("gzip");
  const cw = cs.writable.getWriter();
  const combinedPromise = new Response(cs.readable).arrayBuffer();
  const enc = new TextEncoder();

  const tstat: unknown[] = [];
  let totalRows = 0;

  for (const t of tables) {
    let from = 0; let all: unknown[] = []; let failed: string | null = null;
    while (true) {
      const { data, error } = await admin.from(t).select("*").range(from, from + PAGE - 1);
      if (error) { failed = error.message; break; }
      all = all.concat(data || []);
      if (!data || data.length < PAGE) break;
      from += PAGE;
    }
    if (failed) { tstat.push({ table: t, error: failed }); continue; }
    const gz = await gzipBytes(enc.encode(JSON.stringify(all)));
    const { error: upErr } = await admin.storage.from(BUCKET).upload(`${folder}/${t}.json.gz`, gz, { contentType: "application/gzip", upsert: true });
    await cw.write(enc.encode(JSON.stringify({ table: t, rows: all }) + "\n"));
    totalRows += all.length;
    tstat.push({ table: t, rows: all.length, ...(upErr ? { upload_error: upErr.message } : {}) });
    all = [];
  }
  await cw.close();
  const combined = new Uint8Array(await combinedPromise);

  const manifest = { created_at: new Date().toISOString(), bucket: BUCKET, folder, total_rows: totalRows, tables: tstat };
  await admin.storage.from(BUCKET).upload(`${folder}/_manifest.json`, new Blob([JSON.stringify(manifest, null, 2)], { type: "application/json" }), { upsert: true });

  const deleted: string[] = [];
  const { data: roots } = await admin.storage.from(BUCKET).list("", { limit: 1000, sortBy: { column: "name", order: "asc" } });
  const backupFolders = (roots || []).filter((r) => r.name.startsWith("backup-")).map((r) => r.name).sort();
  if (backupFolders.length > KEEP_LAST) {
    for (const f of backupFolders.slice(0, backupFolders.length - KEEP_LAST)) {
      const { data: files } = await admin.storage.from(BUCKET).list(f, { limit: 1000 });
      const paths = (files || []).map((x) => `${f}/${x.name}`);
      if (paths.length) await admin.storage.from(BUCKET).remove(paths);
      deleted.push(f);
    }
  }

  let drive: Record<string, unknown> = { skipped: "no GDRIVE OAuth secrets" };
  const folderIdRaw = Deno.env.get("GDRIVE_FOLDER_ID");
  const clientId = Deno.env.get("GDRIVE_CLIENT_ID");
  const clientSecret = Deno.env.get("GDRIVE_CLIENT_SECRET");
  const refresh = Deno.env.get("GDRIVE_REFRESH_TOKEN");
  if (folderIdRaw && clientId && clientSecret && refresh) {
    try {
      const folderId = cleanFolderId(folderIdRaw);
      const dtok = await getTokenViaRefresh(clientId, clientSecret, refresh);
      const up = await driveUpload(dtok, folderId, `${folder}.ndjson.gz`, combined);
      let drivePruned = 0;
      try {
        const listed = (await driveList(dtok, folderId)).sort((a, b) => (a.name < b.name ? -1 : 1));
        if (listed.length > KEEP_LAST) {
          for (const f of listed.slice(0, listed.length - KEEP_LAST)) { await driveDelete(dtok, f.id); drivePruned++; }
        }
      } catch (_e) { /* تجاهل فشل التنظيف */ }
      drive = up.id ? { uploaded: true, folder_id: folderId, file: up, pruned: drivePruned } : { uploaded: false, folder_id: folderId, resp: up };
    } catch (e) {
      drive = { uploaded: false, error: String(e) };
    }
  }

  const errs = tstat.filter((x) => (x as Record<string, unknown>).error);
  return new Response(JSON.stringify({ ok: true, folder, tables: tables.length, total_rows: totalRows, archive_bytes: combined.length, deleted_old: deleted.length, errors: errs, drive }), { headers: { "Content-Type": "application/json" } });
});
