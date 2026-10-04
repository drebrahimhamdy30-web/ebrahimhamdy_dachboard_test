import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   رابط المورّد — النقطة العامة الوحيدة
   ═══════════════════════════════════════════════════════════════════
   المورّد بيفتح صفحة `supplier.html?t=<token>` ويعلّم المتاح عنده.
   الصفحة **مافيهاش ولا مفتاح** — بتنادي الدالة دي وبس، والدالة هي
   اللي عندها service_role جوّه السيرفر.

   ⚠️ verify_jwt لازم تبقى **false** للدالة دي (نقطة عامة بطبيعتها).
      والبوابة بتعيدها true مع **كل deploy** — راجع
      [[pharma-sync-scheduler]]: الأعراض بتبقى 401 من البوابة من غير
      أي أثر في لوج الدالة، فلو الصفحة قالت «تعذّر الفتح» افحص ده أول
      حاجة.

   الحراسة:
     • التوكن مخزّن **مهشّر** (sha256) — بنهشّر الجاي ونقارن
     • صلاحية بالتاريخ + علم إلغاء
     • حد أقصى 300 فتحة لكل رابط (سبام)
     • بيرجّع **كود + اسم + كمية** بس — مفيش أسعار ولا خصومات ولا
       مخازن تانية ولا فروع تانية
     • الرد بينزل `reply` ومابيدخلش «تحت الطلب» غير لما حد عندنا
       يضغط اعتماد (supplier_link_apply)

   الاستعمال:
     GET  ?t=<token>            → بيانات الطلبية
     POST ?t=<token> {codes:[]} → حفظ الرد
   ═══════════════════════════════════════════════════════════════════ */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const MAX_OPENS = 300;

function res(b: unknown, s = 200) {
  return new Response(JSON.stringify(b), {
    status: s,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const token = new URL(req.url).searchParams.get("t") || "";
  /* 64 حرف hex — بنرفض أي شكل تاني من غير ما نلمس القاعدة أصلًا */
  if (!/^[0-9a-f]{64}$/.test(token)) return res({ error: "رابط غير صالح" }, 400);

  const hash = await sha256Hex(token);
  const { data: row, error } = await db
    .from("supplier_links")
    .select("id,branch,store,items,reply,note,expires_at,open_count,submitted_at,revoked")
    .eq("token_hash", hash)
    .maybeSingle();

  if (error) return res({ error: "خطأ في الخادم" }, 500);
  if (!row) return res({ error: "رابط غير صالح" }, 404);
  if (row.revoked) return res({ error: "الرابط أُلغي" }, 403);
  if (new Date(row.expires_at) < new Date()) return res({ error: "انتهت صلاحية الرابط" }, 403);
  if (row.open_count >= MAX_OPENS) return res({ error: "تم تجاوز الحد المسموح لهذا الرابط" }, 429);

  if (req.method === "GET") {
    await db.from("supplier_links").update({
      opened_at: row.submitted_at ? undefined : new Date().toISOString(),
      open_count: row.open_count + 1,
    }).eq("id", row.id);

    return res({
      store: row.store,
      items: row.items,                       // [{code,name,qty}] وبس
      submitted: !!row.submitted_at,
      marked: row.reply || [],
      note: row.note || "",
    });
  }

  if (req.method === "POST") {
    let body: { codes?: unknown; note?: unknown };
    try { body = await req.json(); } catch { return res({ error: "بيانات غير صالحة" }, 400); }

    const valid = new Set((row.items as { code: string }[]).map((x) => String(x.code)));
    /* بنقبل الأكواد اللي في الطلبية دي بس — أي كود تاني بيتجاهل */
    const codes = Array.isArray(body.codes)
      ? [...new Set(body.codes.map(String).filter((c) => valid.has(c)))]
      : [];
    const note = typeof body.note === "string" ? body.note.slice(0, 500) : null;

    const { error: upErr } = await db.from("supplier_links").update({
      reply: codes, note, submitted_at: new Date().toISOString(),
    }).eq("id", row.id);
    if (upErr) return res({ error: "تعذّر الحفظ" }, 500);

    return res({ ok: true, saved: codes.length });
  }

  return res({ error: "طريقة غير مدعومة" }, 405);
});
