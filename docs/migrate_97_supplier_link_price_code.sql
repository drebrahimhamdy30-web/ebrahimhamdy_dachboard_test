/* ═══════════════════════════════════════════════════════════════════
   رابط المورّد: سعر البيع والخصم وكود المورّد في كل سطر
   ═══════════════════════════════════════════════════════════════════
   ── الطلب ───────────────────────────────────────────────────────
   المورّد لازم يشوف **سعر البيع والخصم عنده** و**كوده هو** — عشان
   يراجع بسرعة ويلاقي الصنف في نظامه من غير ما يدوّر بالاسم.

   كود المورّد موجود عند **فارما اوفر سيز** و**ابن سينا** بس
   (21,384 و14,793 صف كلهم عندهم `supplier_code`)، وباقي المخازن
   **صفر** — دول بياناتهم جايّة من ملفات مالهاش أكواد. فالحقل بيتساب
   فاضي ومابيتعرضش أصلًا.

   ── ليه التعبئة هنا مش في المتصفح ───────────────────────────────
   الشاشة كانت هتحتاج تسحب كل أكواد المخزن (9 آلاف صف لفارما) عشان
   تلزق كود لكل سطر. التعبئة في الدالة = join واحد جوّه القاعدة،
   والأسعار بتطلع من الكتالوج نفسه فمستحيل تختلف عن اللي الشاشة
   بتعرضه.

   ⚠️ **`store_item_prices` مفتاحه (الاسم، المخزن) مش (الكود، المخزن)**
      — يعني المخزن الواحد ممكن يكون عنده **أكتر من صف بنفس الكود**
      (لقينا فعلًا كود 64842 في ماك ميامى مرتين بأسمين). فاللزقة
      بـjoin عادي كانت هتكرّر السطر في الطلبية. بنستخدم lateral
      بـlimit 1: الأولوية للصف اللي اسمه مطابق، وبعدين الأرخص.

   ⚠️ ده **مش تسريب** — السعر والخصم دول بتوع المورّد نفسه وهو عارفهم.
      اللي بنفضل مانبعتهوش هو أسعار المخازن التانية وتكلفتنا ومخزوننا.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.supplier_link_create(
  p_branch text, p_store text, p_items jsonb, p_days int default 7)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare v_token text; v_id bigint; v_items jsonb;
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

  /* تعبئة السعر والخصم وكود المورّد من كتالوج المخزن — الترتيب
     محفوظ بـwith ordinality عشان تبويبات الفروع تفضل متجمّعة. */
  select jsonb_agg(x.o order by x.ord) into v_items
  from (
    select t.ord,
           jsonb_strip_nulls(
             jsonb_build_object(
               'branch', t.e ->> 'branch',
               'code',   t.e ->> 'code',
               'name',   t.e ->> 'name',
               'qty',    (t.e ->> 'qty')::numeric,
               'price',  sp.price,
               'disc',   sp.discount_perc,
               'scode',  sp.supplier_code)) as o
      from jsonb_array_elements(p_items) with ordinality as t(e, ord)
      left join lateral (
        select s.price, s.discount_perc, s.supplier_code
          from store_item_prices s
         where s.store = p_store and s.code = t.e ->> 'code'
         order by (s.item_name = t.e ->> 'name') desc,
                  (s.price * (1 - coalesce(s.discount_perc, 0) / 100)) asc
         limit 1
      ) sp on true
  ) x;

  v_token := encode(gen_random_bytes(32), 'hex');

  insert into public.supplier_links (token_hash, branch, store, items, created_by, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'),
          p_branch, p_store, v_items,
          coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb
                   -> 'app_metadata' ->> 'full_name', public.jwt_app_role()),
          now() + make_interval(days => greatest(1, least(30, p_days))))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'token', v_token,
                            'expires_at', now() + make_interval(days => p_days));
end
$fn$;

revoke all on function public.supplier_link_create(text, text, jsonb, int) from public, anon;
grant execute on function public.supplier_link_create(text, text, jsonb, int) to authenticated, service_role;
