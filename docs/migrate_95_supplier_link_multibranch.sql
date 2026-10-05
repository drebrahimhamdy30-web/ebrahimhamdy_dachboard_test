/* ═══════════════════════════════════════════════════════════════════
   رابط المورّد: كل الفروع في رابط واحد + كميات محفوظة
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   الرابط كان لفرع واحد، والمورّد ياخد رابط لكل فرع. وأسوأ من كده:
   الكميات المعدَّلة قبل الإنشاء كانت في **ذاكرة المتصفح** بمفتاح
   الكود لوحده (`ORD_SEND`)، فكانت بتتمسح في تلات حالات:
     • تبديل الفرع  — مقصود، لأن المفتاح من غير فرع كان هيخلّي صنف
       بنفس الكود في فرع تاني ياخد كمية الفرع الأول بالغلط
     • زر «إعادة حساب»
     • تحديث الصفحة أو إغلاقها

   يعني اللي يحدّد كميات فرع وينقل للتاني بيلاقي الأول اتمسح. وده
   بيمنع أصلًا إن رابط واحد ياخد كل الفروع.

   ── العلاج ──────────────────────────────────────────────────────
   1. جدول `order_send_qty` مفتاحه **(الفرع، الكود)** — توأم
      `order_selections` بالظبط. الكمية بتعيش عبر الفروع وعبر تحديث
      الصفحة وعبر الكرون اللي بيعيد حساب `purchase_orders_flat` كل 10
      دقايق، وبتبان لأي حساب مشتريات تاني يكمّل الطلبية.
      وبتتمسح مع «بدء يوم جديد» زي باقي التحديدات.

   2. الرابط بقى **متعدّد الفروع**: `items` شكلها
      `[{branch,code,name,qty}]` و`reply` بقت `[{b,c}]` بدل قائمة
      أكواد — المورّد بيعلّم **سطر لكل فرع**، فيقدر يقول «متاح
      للمعمورة ومش متاح لسان ستيفانو» وده بيحصل فعلًا لما كميته
      محدودة. العمود `branch` بقى يقبل NULL = الرابط لكل الفروع.

   ⚠️ **التوافق مع الروابط القديمة إلزامي** — فيه روابط مبعوتة بالفعل
      ردّها `["كود",…]` و`items` بلا فرع. فـ`supplier_link_apply`
      بتتعامل مع الشكلين: العنصر لو نص ياخد الفرع من العمود، ولو كائن
      ياخده من جوّاه. نفس الحكاية في الـEdge Function.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) الكميات المعدَّلة — محفوظة على السيرفر ─────────────────── */
create table if not exists public.order_send_qty (
  branch     text        not null,
  itm_code   text        not null,
  qty        numeric     not null check (qty >= 0),
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (branch, itm_code)
);

comment on table public.order_send_qty is
  'الكمية اللي المشتريات حدّدتها لصنف في فرع، بتتغلّب على net_required المحسوب. تتمسح مع «بدء يوم جديد».';

alter table public.order_send_qty enable row level security;
revoke all on public.order_send_qty from anon, public;
drop policy if exists order_send_qty_auth on public.order_send_qty;
create policy order_send_qty_auth on public.order_send_qty
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.order_send_qty to authenticated;
grant all on public.order_send_qty to service_role;

/* ── 2) الرابط يقبل أكتر من فرع ────────────────────────────────── */
alter table public.supplier_links alter column branch drop not null;

comment on column public.supplier_links.branch is
  'فرع الرابط، أو NULL لو الرابط لكل الفروع (الفرع ساعتها جوّه كل عنصر في items).';
comment on column public.supplier_links.items is
  '[{branch,code,name,qty}] — والروابط القديمة [{code,name,qty}] والفرع من العمود.';
comment on column public.supplier_links.reply is
  '[{b,c}] سطر لكل (فرع، كود) — والروابط القديمة ["كود",…].';

/* ── 3) الإنشاء: نفس البصمة، و p_branch بيبقى NULL للمتعدّد ──────
   مابنعملش overload عن قصد — توقيع تاني بنفس الاسم بيخلّي PostgREST
   يلخبط بين الاتنين (PGRST203). */
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

  /* الرابط المتعدّد لازم كل عنصر يقول فرعه، وإلا الاعتماد مايعرفش
     يحطّ الصنف تحت الطلب في أنهي فرع. */
  if p_branch is null and exists (
    select 1 from jsonb_array_elements(p_items) e
     where coalesce(nullif(e ->> 'branch', ''), '') = ''
  ) then
    raise exception 'الرابط لكل الفروع لازم كل صنف يحمل فرعه';
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

/* ── 4) الاعتماد: سطر لكل (فرع، كود) ───────────────────────────── */
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

  /* الشكل الجديد {b,c} والقديم "كود" — الاتنين بيتسوّوا هنا */
  with lines as (
    select distinct
           case when jsonb_typeof(e) = 'object'
                then coalesce(nullif(e ->> 'b', ''), r.branch)
                else r.branch end as branch,
           case when jsonb_typeof(e) = 'object'
                then e ->> 'c'
                else e #>> '{}' end as itm_code
      from jsonb_array_elements(r.reply) e
  ),
  ins as (
    insert into public.order_selections (branch, itm_code, stock_at_order)
    select l.branch, l.itm_code,
           (select pof.stock from purchase_orders_flat pof
             where pof.branch = l.branch and pof.itm_code = l.itm_code limit 1)
      from lines l
     where l.branch is not null and coalesce(l.itm_code, '') <> ''
    on conflict (branch, itm_code) do update set stock_at_order = excluded.stock_at_order
    returning 1
  )
  select count(*) into n from ins;

  update public.supplier_links set applied_at = now() where id = p_id;
  return jsonb_build_object('added', n);
end
$fn$;

revoke all on function public.supplier_link_create(text, text, jsonb, int) from public, anon;
revoke all on function public.supplier_link_apply(bigint)                  from public, anon;
grant execute on function public.supplier_link_create(text, text, jsonb, int) to authenticated, service_role;
grant execute on function public.supplier_link_apply(bigint)                  to authenticated, service_role;
