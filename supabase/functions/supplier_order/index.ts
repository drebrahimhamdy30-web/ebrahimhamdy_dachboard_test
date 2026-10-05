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
     • بيرجّع **فرع + كود + اسم + كمية** بس — مفيش أسعار ولا خصومات
       ولا مخازن تانية
     • الرد بينزل `reply` ومابيدخلش «تحت الطلب» غير لما حد عندنا
       يضغط اعتماد (supplier_link_apply)

   ── الرابط متعدّد الفروع ─────────────────────────────────────────
   الطلبية بقت سطر لكل (فرع، كود)، والمورّد بيعلّم في تبويب كل فرع
   لوحده — عشان يقدر يقول «متاح للمعمورة ومش متاح لسان ستيفانو» لما
   كميته محدودة.

   ⚠️ **شكلين لازم يفضلوا شغّالين** — فيه روابط مبعوتة قبل التعديل:
     items:  [{branch,code,name,qty}] الجديد · [{code,name,qty}] القديم
             (الفرع ساعتها من عمود `branch` في الصف)
     reply:  [{b,c}] الجديد · ["كود",…] القديم
   والـPOST بيقبل `lines` الجديدة و`codes` القديمة (لو متصفّح المورّد
   مكرّش نسخة قديمة من الصفحة) — الكود القديم بيتفسّر «متاح في كل
   الفروع اللي الصنف مطلوب فيها».

   الاستعمال:
     GET  ?t=<token>                      → بيانات الطلبية
     POST ?t=<token> {lines:[{b,c}]}      → حفظ الرد
   ═══════════════════════════════════════════════════════════════════ */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const MAX_OPENS = 300;

type Item = { branch?: string; code: string; name?: string; qty?: number };
type Line = { b: string; c: string };

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

/* مفتاح السطر — اسم الفرع مابيحتويش على \u0001 فمفيش لبس */
const K = (b: string, c: string) => b + "\u0001" + c;

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

  /* كل سطر بيطلع ومعاه فرعه — القديم بياخده من العمود */
  const raw: Item[] = Array.isArray(row.items) ? row.items : [];
  const items = raw.map((x) => ({
    branch: String(x.branch || row.branch || ""),
    code: String(x.code),
    name: x.name,
    qty: x.qty,
  })).filter((x) => x.code && x.branch);

  if (req.method === "GET") {
    await db.from("supplier_links").update({
      opened_at: row.submitted_at ? undefined : new Date().toISOString(),
      open_count: row.open_count + 1,
    }).eq("id", row.id);

    /* الرد المحفوظ بيرجع بشكل واحد — الصفحة ماتشيلش هم القديم */
    const rep: unknown[] = Array.isArray(row.reply) ? row.reply : [];
    const marked: Line[] = rep.flatMap((e) => {
      if (e && typeof e === "object") {
        const o = e as { b?: string; c?: string };
        return o.c ? [{ b: String(o.b || row.branch || ""), c: String(o.c) }] : [];
      }
      const c = String(e);
      return items.filter((x) => x.code === c).map((x) => ({ b: x.branch, c }));
    });

    return res({
      store: row.store,
      items,                                  // [{branch,code,name,qty}]
      submitted: !!row.submitted_at,
      marked,                                 // [{b,c}]
      note: row.note || "",
    });
  }

  if (req.method === "POST") {
    let body: { lines?: unknown; codes?: unknown; note?: unknown };
    try { body = await req.json(); } catch { return res({ error: "بيانات غير صالحة" }, 400); }

    const valid = new Set(items.map((x) => K(x.branch, x.code)));

    /* بنقبل سطور الطلبية دي بس — أي سطر تاني بيتجاهل */
    let lines: Line[] = [];
    if (Array.isArray(body.lines)) {
      lines = (body.lines as { b?: unknown; c?: unknown }[])
        .map((o) => ({ b: String(o?.b ?? ""), c: String(o?.c ?? "") }))
        .filter((o) => valid.has(K(o.b, o.c)));
    } else if (Array.isArray(body.codes)) {
      /* نسخة صفحة قديمة: الكود = متاح في كل فروعه */
      const set = new Set((body.codes as unknown[]).map(String));
      lines = items.filter((x) => set.has(x.code)).map((x) => ({ b: x.branch, c: x.code }));
    }

    /* إزالة التكرار بعد التصفية */
    const seen = new Set<string>();
    lines = lines.filter((o) => {
      const k = K(o.b, o.c);
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });

    const note = typeof body.note === "string" ? body.note.slice(0, 500) : null;

    const { error: upErr } = await db.from("supplier_links").update({
      reply: lines, note, submitted_at: new Date().toISOString(),
    }).eq("id", row.id);
    if (upErr) return res({ error: "تعذّر الحفظ" }, 500);

    return res({ ok: true, saved: lines.length });
  }

  return res({ error: "طريقة غير مدعومة" }, 405);
});
