import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/* ═══════════════════════════════════════════════════════════════════
   تقييم العميل — النقطة العامة الوحيدة
   ═══════════════════════════════════════════════════════════════════
   العميل بيفتح `rate.html?t=<token>` ويقيّم الصيدلي ومندوب التوصيل.
   الصفحة **مافيهاش ولا مفتاح** — بتنادي الدالة دي وبس، والدالة هي
   اللي عندها service_role جوّه السيرفر. نفس نمط `supplier_order`.

   ⚠️ verify_jwt لازم تبقى **false** (نقطة عامة بطبيعتها). على السحابة
      البوابة بتعيدها true مع كل deploy — راجع [[pharma-sync-scheduler]].
      على السيرفر الذاتي الراوتر (main/) هو اللي بيقرر — لازم تتضاف
      لقائمة الدوال المفتوحة هناك.

   الحراسة:
     • التوكن 32 حرف hex، مخزّن **مهشّر** (sha256) — بنهشّر الجاي ونقارن
     • صلاحية بالتاريخ (expires_at) + حالة الرابط
     • حد أقصى 200 فتحة لكل رابط (سبام)
     • التقييم **مرة واحدة** — بعده أي POST بيترفض بـ409
     • بيرجّع: اسم المؤسسة وشعارها ولونها، اسم الفرع، رقم الفاتورة،
       تاريخ التوصيل. **مابيرجّعش**: اسم العميل، رقمه، المبلغ، الأصناف،
       اسم الصيدلي أو المندوب (قرار: التقييم على التجربة مش على الشخص).

   الاستعمال:
     GET  ?t=<token>                          → بيانات الرابط وحالته
     POST ?t=<token> {e:1..5, d:1..5, c:""}   → حفظ التقييم
   ═══════════════════════════════════════════════════════════════════ */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const MAX_OPENS = 200;

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

function star(v: unknown): number | null {
  const n = Number(v);
  return Number.isInteger(n) && n >= 1 && n <= 5 ? n : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const token = new URL(req.url).searchParams.get("t") || "";
  /* 32 حرف hex — بنرفض أي شكل تاني من غير ما نلمس القاعدة أصلًا */
  if (!/^[0-9a-f]{32}$/.test(token)) return res({ error: "رابط غير صالح" }, 400);

  const hash = await sha256Hex(token);
  const { data: row, error } = await db
    .from("order_rating_links")
    .select("id,branch_id,bill_no,delivered_at,status,expires_at,open_count,opened_at,rated_at,sent_at")
    .eq("token_hash", hash)
    .maybeSingle();

  if (error) return res({ error: "خطأ في الخادم" }, 500);
  if (!row) return res({ error: "رابط غير صالح" }, 404);

  /* الهوية والفرع — بيرجعوا مع كل حالة عشان الصفحة تتلوّن حتى لو منتهي */
  const [{ data: org }, { data: br }] = await Promise.all([
    db.from("org_settings").select("company_name,logo_url,brand_primary,brand_primary_dark").eq("id", 1).maybeSingle(),
    row.branch_id
      ? db.from("branches").select("name").eq("id", row.branch_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const base = {
    org: {
      name: org?.company_name || "الصيدلية",
      logo: org?.logo_url || "",
      color: org?.brand_primary || "#0d9488",
      color_dark: org?.brand_primary_dark || "#0f766e",
    },
    branch: br?.name || "",
    bill_no: row.bill_no || "",
    delivered_at: row.delivered_at,
  };

  const state =
    row.rated_at || row.status === "rated" ? "rated"
    : (row.expires_at && new Date(row.expires_at) < new Date()) || row.status === "expired" ? "expired"
    : row.status === "sent" ? "open"
    : "invalid";   // pending (اتعمل له إرجاع) أو dropped — التوكن القديم مابقاش يفتح

  if (req.method === "GET") {
    if (state === "invalid") return res({ ...base, state: "expired" });
    if (state === "open") {
      if (row.open_count >= MAX_OPENS) return res({ error: "تم تجاوز الحد المسموح لهذا الرابط" }, 429);
      await db.from("order_rating_links").update({
        opened_at: row.opened_at ?? new Date().toISOString(),
        open_count: row.open_count + 1,
      }).eq("id", row.id);
    }
    return res({ ...base, state });
  }

  if (req.method === "POST") {
    if (state === "rated") return res({ error: "تم إرسال التقييم من هذا الرابط بالفعل." }, 409);
    if (state !== "open") return res({ error: "انتهت صلاحية هذا الرابط." }, 403);

    let body: { e?: unknown; d?: unknown; c?: unknown };
    try { body = await req.json(); } catch { return res({ error: "بيانات غير صالحة" }, 400); }

    const e = star(body.e), d = star(body.d);
    if (!e || !d) return res({ error: "من فضلك اختر تقييم الصيدلي ومندوب التوصيل (1 إلى 5)" }, 400);
    const c = typeof body.c === "string" ? body.c.trim().slice(0, 600) : null;

    /* الكتابة مشروطة بإن الرابط لسه مفتوح — ضد الضغط مرتين في نفس اللحظة */
    const { data: upd, error: upErr } = await db.from("order_rating_links")
      .update({ employee_stars: e, driver_stars: d, comment: c || null,
                rated_at: new Date().toISOString(), status: "rated" })
      .eq("id", row.id).eq("status", "sent").is("rated_at", null)
      .select("id");
    if (upErr) return res({ error: "تعذّر الحفظ" }, 500);
    if (!upd || !upd.length) return res({ error: "تم إرسال التقييم من هذا الرابط بالفعل." }, 409);

    return res({ ok: true });
  }

  return res({ error: "طريقة غير مدعومة" }, 405);
});
