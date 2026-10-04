/* ═══════════════════════════════════════════════════════════════════
   رابط المورّد — يعلّم المتاح عنده من موبايله بدل ملف إكسل
   ═══════════════════════════════════════════════════════════════════
   الدورة الحالية: نصدّر إكسل → المورّد يعلّم عمود → يبعته → نستورده.
   هشّة: نسخ متعددة، صفوف متمسوحة، ترتيب متغيّر، ومحدش عارف الرد جه
   امتى. وممنوع checkbox حقيقي في الإكسل (النسخة المجانية من SheetJS
   مابتكتبش form controls ولا data validation).

   البديل: لينك. المورّد يفتحه بأي متصفح، يعلّم بـcheckbox حقيقي،
   يضغط إرسال — والرد ينزل عندنا فورًا.

   ── الأمان (ده كان سؤال المالك الأساسي) ────────────────────────
   1. **الصفحة مافيهاش ولا مفتاح.** بتنادي Edge Function واحدة بس،
      والدالة بتشتغل بـservice_role جوّه السيرفر. فمفيش مفتاح يتسرّب
      من الصفحة مهما حصل.
   2. التوكن **32 بايت عشوائي** ومخزّن **مهشّر** (sha256) — تسريب
      الجدول نفسه مايدّيش حد رابط شغّال.
   3. صلاحية افتراضية **7 أيام** وقابل للإلغاء في أي لحظة.
   4. الرابط بيشوف **طلبيته هو بس**: كود + اسم + كمية.
      **مفيش أسعار ولا خصومات ولا مخازن تانية ولا فروع تانية.**
   5. الرد بينزل في `reply` — **مابيدخلش «تحت الطلب»** إلا لما مستخدم
      عندنا يراجع ويضغط اعتماد. فحتى لو حد علّم كل حاجة، إنت اللي
      بتقرر.
   6. حد أقصى للفتحات (`open_count`) ضد السبام.
   7. كل فتح وكل إرسال بيتسجّل بوقته.

   ⚠️ الجدول مقفول على anon تمامًا — الوصول الوحيد عبر الدالة.
      راجع [[anon-key-lockdown]]: أي دالة جديدة لازم يتسحب منها
      PUBLIC و anon صراحةً وإلا بتفتح الباب لوحدها.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.supplier_links (
  id           bigserial primary key,
  token_hash   text        not null unique,
  branch       text        not null,
  store        text        not null,
  items        jsonb       not null default '[]'::jsonb,   -- [{code,name,qty}]
  reply        jsonb,                                       -- [codes...] المتاح
  note         text,                                        -- ملاحظة المورّد
  created_by   text,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  opened_at    timestamptz,
  open_count   int         not null default 0,
  submitted_at timestamptz,
  applied_at   timestamptz,
  revoked      boolean     not null default false
);

create index if not exists supplier_links_branch_idx on public.supplier_links (branch, created_at desc);

alter table public.supplier_links enable row level security;
revoke all on public.supplier_links from anon, public;
drop policy if exists supplier_links_auth on public.supplier_links;
create policy supplier_links_auth on public.supplier_links
  for all to authenticated using (true) with check (true);
grant select, insert, update on public.supplier_links to authenticated;
grant usage, select on sequence public.supplier_links_id_seq to authenticated;
/* ⚠️ لازم صراحةً: `revoke ... from public` فوق بيسحب كمان الصلاحية
   اللي service_role كان معتمد عليها، والـEdge Function بتكتب بيه —
   من غير السطرين دول الإرسال بيرجّع 500 «تعذّر الحفظ». */
grant all on public.supplier_links to service_role;
grant usage, select on sequence public.supplier_links_id_seq to service_role;

/* ── إنشاء رابط ─────────────────────────────────────────────────
   بترجّع التوكن **الخام مرة واحدة بس** — المخزّن مهشّر، فلو ضاع
   تعمل رابط جديد. */
create or replace function public.supplier_link_create(
  p_branch text, p_store text, p_items jsonb, p_days int default 7)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_token text; v_id bigint;
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);

  if coalesce(jsonb_array_length(p_items), 0) = 0 then
    raise exception 'مفيش أصناف في الطلبية';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.supplier_links (token_hash, branch, store, items, created_by, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'),
          p_branch, p_store, p_items,
          coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb
                   -> 'app_metadata' ->> 'full_name', public.jwt_app_role()),
          now() + make_interval(days => greatest(1, least(30, p_days))))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'token', v_token,
                            'expires_at', now() + make_interval(days => p_days));
end
$fn$;

/* ── إلغاء رابط ─────────────────────────────────────────────────── */
create or replace function public.supplier_link_revoke(p_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);
  update public.supplier_links set revoked = true where id = p_id;
  return found;
end
$fn$;

/* ── اعتماد الرد: الأصناف المعلَّمة تدخل «تحت الطلب» ─────────────
   خطوة بشرية مقصودة — الرد لوحده مابيأثرش على الشراء. */
create or replace function public.supplier_link_apply(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare r record; n int := 0;
begin
  perform public.require_app_role(array['admin','manager','pharmacist']);

  select * into r from public.supplier_links where id = p_id;
  if not found then raise exception 'الرابط مش موجود'; end if;
  if r.reply is null then raise exception 'مفيش رد من المورّد لسه'; end if;

  insert into public.order_selections (branch, itm_code, stock_at_order)
  select r.branch, c.code,
         (select pof.stock from purchase_orders_flat pof
           where pof.branch = r.branch and pof.itm_code = c.code limit 1)
    from jsonb_array_elements_text(r.reply) as c(code)
  on conflict (branch, itm_code) do update set stock_at_order = excluded.stock_at_order;
  get diagnostics n = row_count;

  update public.supplier_links set applied_at = now() where id = p_id;
  return jsonb_build_object('added', n);
end
$fn$;

/* الصلاحيات: الدوال دي للمستخدمين المسجّلين بس — الصفحة العامة
   بتعدّي على Edge Function بـservice_role مش على الدوال دي. */
revoke all on function public.supplier_link_create(text, text, jsonb, int) from public, anon;
revoke all on function public.supplier_link_revoke(bigint)                 from public, anon;
revoke all on function public.supplier_link_apply(bigint)                  from public, anon;
grant execute on function public.supplier_link_create(text, text, jsonb, int) to authenticated, service_role;
grant execute on function public.supplier_link_revoke(bigint)                 to authenticated, service_role;
grant execute on function public.supplier_link_apply(bigint)                  to authenticated, service_role;
