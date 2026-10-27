/* ============================================================
   متعلقات العميل — حاجة عند الصيدلية لازم ترجع لصاحبها
   ------------------------------------------------------------
   الحالة اللي بدأ منها الطلب: العميل عمل مرتجع واترفض، فالصنف لازم
   يرجع له مع أول طلب جاي. المشكلة اللي سألها المالك: «هيظهر مع كل
   طلب — إزاي نعرف إنه رجع عشان ما يظهرش تاني؟»

   🔑 **الإجابة: مفيش إشارة تلقائية، ولازم ما تكونش.**
   لو قفلناه تلقائيًا مع تسليم الطلب، الطلب يتسلّم والمتعلّق منسي في
   الصيدلية فيختفي من الشاشة وهو لسه موجود — وده أسوأ من إنه يفضل
   ظاهر. فالقفل **تأكيد بشري** في خطوتين (قرار المالك 2026-10-27):

     معلّق ──[الطيار: «سلّمته»]──► بانتظار تأكيد الصيدلية
                                        │
                                        └──[الصيدلية تؤكّد]──► تم التسليم

   • وهو «بانتظار التأكيد» بيختفي من شاشة الطيار (ما يتسلّمش مرتين)
     وبيفضل في قايمة الصيدلية لحد ما تأكّد.
   • الطيار لو راح وماسلّمش: «ماتسلّمش» بسبب → يرجع معلّق و**عدّاد
     المحاولات يزيد**. «راح مع ٣ طلبات وماتسلّمش» دي إشارة لوحدها.
   • الإلغاء لحالة «اتقرر ما يرجعش» بسبب مكتوب.

   قرارات المالك: أي موظف فرع ينشئ · الصيدلية تؤكّد بعد الطيار ·
   **وصف بس بلا قيمة مالية**.

   ⚠️ الفرع: المتعلّق موجود فيزيائيًا في فرع واحد. على طلب من فرع تاني
   بيظهر **تنبيه بلا زر تسليم** — الطيار مش معاه الحاجة أصلًا.

   الربط بالعميل بالكود: ٩٧.٧٪ من طلبات آخر شهر عندها `cust_code`
   (١٩٬٣٩٧ طلب، ٤٤٨ بس بلا كود)، والتليفون احتياطي للباقي.
   ============================================================ */

create table if not exists public.customer_belongings (
  id             bigserial primary key,
  cust_code      text,
  customer_name  text,
  customer_phone text,
  branch_id      uuid references public.branches(id),
  kind           text not null default 'مرتجع مرفوض',
  details        text not null,
  status         text not null default 'open'
                 check (status in ('open','delivered_pending','confirmed','cancelled')),
  attempts       integer not null default 0,
  last_attempt_at   timestamptz,
  last_attempt_note text,
  created_at     timestamptz not null default now(),
  created_by     text,
  delivered_at   timestamptz,
  delivered_by   text,
  delivered_order_id uuid references public.orders(id),
  confirmed_at   timestamptz,
  confirmed_by   text,
  closed_note    text
);

/* الفهرس اللي الطلب بيتسأل بيه: كل طلب بيدوّر على متعلقات عميله */
create index if not exists ix_belongings_open_code
  on public.customer_belongings (cust_code) where status = 'open';
create index if not exists ix_belongings_open_phone
  on public.customer_belongings (customer_phone) where status = 'open';
create index if not exists ix_belongings_branch_status
  on public.customer_belongings (branch_id, status, created_at desc);

alter table public.customer_belongings enable row level security;
drop policy if exists belongings_read on public.customer_belongings;
create policy belongings_read on public.customer_belongings
  for select to authenticated using (true);

/* ⚠️ الكتابة بالدوال بس — PUBLIC بياخد صلاحيات افتراضية فلازم السحب
   الصريح، وanon مالوش علاقة بالجدول ده. */
revoke all on public.customer_belongings from public, anon, authenticated;
grant select on public.customer_belongings to authenticated;
grant usage, select on sequence public.customer_belongings_id_seq to authenticated;

/* ── مين بيعمل الإجراء: الاسم الحقيقي مش حساب عام ──────────── */
create or replace function public.belonging_actor()
returns text language sql stable as $$
  select coalesce(
    nullif(btrim(nullif(current_setting('request.jwt.claims', true),'')::jsonb -> 'app_metadata' ->> 'full_name'),''),
    nullif(btrim(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'full_name'),''),
    nullif(btrim(nullif(current_setting('request.jwt.claims', true),'')::jsonb -> 'app_metadata' ->> 'username'),''),
    'غير معروف');
$$;

/* ── إنشاء: أي موظف فرع (قرار المالك) ───────────────────────── */
create or replace function public.create_customer_belonging(
  p_cust_code text, p_customer_name text, p_customer_phone text,
  p_branch text, p_kind text, p_details text
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_bid uuid; v_id bigint;
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  if coalesce(btrim(p_details),'') = '' then
    raise exception 'الوصف مطلوب' using errcode = '22023';
  end if;
  if coalesce(btrim(coalesce(p_cust_code,'')),'') = ''
     and coalesce(btrim(coalesce(p_customer_phone,'')),'') = '' then
    raise exception 'لا بد من كود العميل أو رقم هاتفه' using errcode = '22023';
  end if;

  select b.id into v_bid from branches b
   where b.code = public.branch_code_of(p_branch) limit 1;

  insert into customer_belongings
    (cust_code, customer_name, customer_phone, branch_id, kind, details, created_by)
  values (nullif(btrim(coalesce(p_cust_code,'')),''),
          nullif(btrim(coalesce(p_customer_name,'')),''),
          nullif(btrim(coalesce(p_customer_phone,'')),''),
          v_bid,
          coalesce(nullif(btrim(coalesce(p_kind,'')),''), 'مرتجع مرفوض'),
          btrim(p_details),
          public.belonging_actor())
  returning id into v_id;

  return jsonb_build_object('success', true, 'id', v_id);
end $$;

/* ── الطيار: سلّمته / ماتسلّمش ──────────────────────────────── */
create or replace function public.belonging_mark_delivered(
  p_id bigint, p_order_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_st text;
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  select status into v_st from customer_belongings where id = p_id;
  if v_st is null then raise exception 'المتعلّق غير موجود' using errcode = 'P0002'; end if;
  if v_st <> 'open' then
    raise exception 'المتعلّق ليس في حالة «معلّق»' using errcode = '22023';
  end if;
  update customer_belongings
     set status='delivered_pending', delivered_at=now(),
         delivered_by=public.belonging_actor(), delivered_order_id=p_order_id
   where id = p_id;
  return jsonb_build_object('success', true);
end $$;

create or replace function public.belonging_mark_failed(
  p_id bigint, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_st text;
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  select status into v_st from customer_belongings where id = p_id;
  if v_st is null then raise exception 'المتعلّق غير موجود' using errcode = 'P0002'; end if;
  /* ⚠️ بيفضل «معلّق» — محاولة فاشلة مش قفل. العدّاد هو اللي بيكشف
     المتعلّق اللي بيروح ويرجع كل مرة. */
  update customer_belongings
     set status='open', attempts = attempts + 1,
         last_attempt_at = now(),
         last_attempt_note = nullif(btrim(coalesce(p_note,'')),'')
   where id = p_id;
  return jsonb_build_object('success', true);
end $$;

/* ── الصيدلية: تأكيد التسليم (الخطوة اللي بتقفل فعلًا) ──────── */
create or replace function public.belonging_confirm(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_st text;
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  select status into v_st from customer_belongings where id = p_id;
  if v_st is null then raise exception 'المتعلّق غير موجود' using errcode = 'P0002'; end if;
  if v_st = 'confirmed' then
    raise exception 'مؤكَّد بالفعل' using errcode = '23505';
  end if;
  update customer_belongings
     set status='confirmed', confirmed_at=now(), confirmed_by=public.belonging_actor(),
         delivered_at = coalesce(delivered_at, now()),
         delivered_by = coalesce(delivered_by, public.belonging_actor())
   where id = p_id;
  return jsonb_build_object('success', true);
end $$;

create or replace function public.belonging_cancel(p_id bigint, p_note text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  if coalesce(btrim(coalesce(p_note,'')),'') = '' then
    raise exception 'سبب الإلغاء مطلوب' using errcode = '22023';
  end if;
  update customer_belongings
     set status='cancelled', closed_note=btrim(p_note),
         confirmed_at=now(), confirmed_by=public.belonging_actor()
   where id = p_id and status <> 'confirmed';
  if not found then raise exception 'تعذّر الإلغاء' using errcode = 'P0002'; end if;
  return jsonb_build_object('success', true);
end $$;

/* ── قراءة: قايمة الصيدلية ─────────────────────────────────── */
create or replace function public.get_belongings(
  p_branch text default null, p_status text default null, p_search text default null
) returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
    from (
      select cb.id, cb.cust_code, cb.customer_name, cb.customer_phone,
             b.name branch_name, cb.kind, cb.details, cb.status, cb.attempts,
             cb.last_attempt_at, cb.last_attempt_note,
             cb.created_at, cb.created_by,
             cb.delivered_at, cb.delivered_by, cb.confirmed_at, cb.confirmed_by, cb.closed_note,
             (extract(epoch from (now() - cb.created_at))/86400)::int days_open
        from customer_belongings cb
        left join branches b on b.id = cb.branch_id
       where (p_branch is null or b.code = public.branch_code_of(p_branch))
         and (p_status is null or cb.status = p_status)
         and (coalesce(btrim(coalesce(p_search,'')),'') = ''
              or cb.cust_code ilike '%'||btrim(p_search)||'%'
              or cb.customer_name ilike '%'||btrim(p_search)||'%'
              or cb.customer_phone ilike '%'||btrim(p_search)||'%'
              or cb.details ilike '%'||btrim(p_search)||'%')
    ) x;
$$;

/* ── قراءة: متعلقات عميل طلب معيّن (التوزيع + الطيار) ────────
   بترجّع «معلّق» بس، ومعاها هل هو في نفس فرع الطلب — الطيار
   مايقدرش يسلّم حاجة موجودة في فرع تاني. */
create or replace function public.get_order_belongings(p_order_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]'::jsonb)
    from (
      select cb.id, cb.kind, cb.details, cb.attempts, cb.last_attempt_note,
             cb.created_at, cb.created_by,
             b.name branch_name,
             (cb.branch_id is not distinct from o.branch_id) same_branch
        from orders o
        join customer_belongings cb
          on cb.status = 'open'
         and ( (coalesce(btrim(coalesce(o.cust_code,'')),'') <> ''
                and cb.cust_code = btrim(o.cust_code))
            or (coalesce(btrim(coalesce(cb.cust_code,'')),'') = ''
                and coalesce(btrim(coalesce(o.customer_phone,'')),'') <> ''
                and cb.customer_phone = btrim(o.customer_phone)) )
        left join branches b on b.id = cb.branch_id
       where o.id = p_order_id
    ) x;
$$;

do $$
declare r record;
begin
  for r in
    select p.proname, pg_get_function_identity_arguments(p.oid) args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('create_customer_belonging','belonging_mark_delivered',
                         'belonging_mark_failed','belonging_confirm','belonging_cancel',
                         'get_belongings','get_order_belongings','belonging_actor')
  loop
    execute format('revoke all on function public.%I(%s) from public, anon', r.proname, r.args);
    execute format('grant execute on function public.%I(%s) to authenticated', r.proname, r.args);
  end loop;
end $$;

/* ════════════════════════════════════════════════════════════════
   161-ب · قصر الفروع على السيرفر  (2026-10-27)
   ----------------------------------------------------------------
   النسخة الأولى كانت `get_belongings` بتقبل أي فرع من أي مستخدم،
   و RLS `using (true)` — يعني موظف فرع يقدر يقرا متعلقات الفروع
   التانية بتغيير بارامتر. القاعدة في المشروع إن الحارس على
   السيرفر مش على إخفاء الزر، فالقصر بيتطبّق هنا.

   الصلاحية بتتقرأ من `page_permissions.all_branches` لصفحة
   `customers` — نفس الصف اللي بيتظبط من شاشة الصلاحيات، فمفيش
   مفتاح جديد يتنسى. (`purchase_branch_scope` عامة على أي صفحة بس
   بترفع استثناء، وده بيكسر سياسة RLS، فعندنا نسخة ساكتة.)
   ════════════════════════════════════════════════════════════════ */

/* كود الفرع اللي المستخدم محصور فيه · null = كل الفروع ·
   '__none__' = مش مصرّح / مش مربوط بفرع. ساكتة بلا استثناء عشان
   تنفع جوّه سياسة RLS. */
create or replace function public.belonging_scope_code()
returns text language plpgsql stable security definer set search_path = public as $fn$
declare v_role text := public.jwt_app_role(); v_all boolean; v_code text; v_br text;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
  then return null; end if;
  if v_role is null then return '__none__'; end if;
  if v_role = 'admin'  then return null; end if;

  select pp.all_branches into v_all
    from page_permissions pp where pp.role = v_role and pp.page_key = 'customers';
  if v_all is null then
    select r.all_branches into v_all from role_branch_scope r where r.role = v_role;
  end if;
  if coalesce(v_all, false) then return null; end if;

  /* ⚠️ التوكن فيه اسم الفرع بالعربي مش الكود، والأسماء فيها ي/ى */
  v_br := public.jwt_branch();
  select b.code into v_code from branches b
   where b.name = v_br or v_br = any(coalesce(b.aliases,'{}'::text[])) limit 1;
  return coalesce(v_code, '__none__');
end $fn$;

/* ── RLS: القراءة المباشرة للجدول مقصورة كمان (خط دفاع تاني) ── */
drop policy if exists belongings_read on public.customer_belongings;
create policy belongings_read on public.customer_belongings
  for select to authenticated using (
    public.belonging_scope_code() is null
    or branch_id in (select id from branches where code = public.belonging_scope_code())
  );

/* ── الإنشاء: الفرع بيتفرض من التوكن، مش من الشاشة ──────────── */
create or replace function public.create_customer_belonging(
  p_cust_code text, p_customer_name text, p_customer_phone text,
  p_branch text, p_kind text, p_details text
) returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_bid uuid; v_id bigint; v_scope text; v_code text;
begin
  v_scope := public.belonging_scope_code();
  if v_scope = '__none__' then
    raise exception 'غير مصرّح: حسابك غير مربوط بفرع محدّد' using errcode = '42501';
  end if;
  if coalesce(btrim(p_details),'') = '' then
    raise exception 'الوصف مطلوب' using errcode = '22023';
  end if;
  if coalesce(btrim(coalesce(p_cust_code,'')),'') = ''
     and coalesce(btrim(coalesce(p_customer_phone,'')),'') = '' then
    raise exception 'لا بد من كود العميل أو رقم هاتفه' using errcode = '22023';
  end if;

  /* موظف الفرع بيسجّل في فرعه هو — المتعلّق حاجة موجودة فيزيائيًا
     عنده. اللي بيشوف كل الفروع هو بس اللي بيختار الفرع. */
  v_code := coalesce(v_scope, public.branch_code_of(p_branch));
  select b.id into v_bid from branches b where b.code = v_code limit 1;
  if v_bid is null then
    raise exception 'الفرع غير معروف' using errcode = '22023';
  end if;

  insert into customer_belongings
    (cust_code, customer_name, customer_phone, branch_id, kind, details, created_by)
  values (nullif(btrim(coalesce(p_cust_code,'')),''),
          nullif(btrim(coalesce(p_customer_name,'')),''),
          nullif(btrim(coalesce(p_customer_phone,'')),''),
          v_bid,
          coalesce(nullif(btrim(coalesce(p_kind,'')),''), 'مرتجع مرفوض'),
          btrim(p_details),
          public.belonging_actor())
  returning id into v_id;

  return jsonb_build_object('success', true, 'id', v_id);
end $fn$;

/* ── حارس مشترك: المتعلّق ده في نطاق المستخدم؟ ──────────────── */
create or replace function public.belonging_assert_scope(p_id bigint)
returns void language plpgsql stable security definer set search_path = public as $fn$
declare v_scope text := public.belonging_scope_code(); v_ok boolean;
begin
  if v_scope = '__none__' then
    raise exception 'غير مصرّح: حسابك غير مربوط بفرع محدّد' using errcode = '42501';
  end if;
  if v_scope is null then return; end if;
  select exists (select 1 from customer_belongings cb
                   join branches b on b.id = cb.branch_id
                  where cb.id = p_id and b.code = v_scope) into v_ok;
  if not v_ok then
    raise exception 'المتعلّق في فرع آخر' using errcode = '42501';
  end if;
end $fn$;

/* ── الصيدلية: التأكيد والإلغاء مقصورين على فرع المتعلّق ────── */
create or replace function public.belonging_confirm(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_st text;
begin
  perform public.belonging_assert_scope(p_id);
  select status into v_st from customer_belongings where id = p_id;
  if v_st is null then raise exception 'المتعلّق غير موجود' using errcode = 'P0002'; end if;
  if v_st = 'confirmed' then
    raise exception 'مؤكَّد بالفعل' using errcode = '23505';
  end if;
  update customer_belongings
     set status='confirmed', confirmed_at=now(), confirmed_by=public.belonging_actor(),
         delivered_at = coalesce(delivered_at, now()),
         delivered_by = coalesce(delivered_by, public.belonging_actor())
   where id = p_id;
  return jsonb_build_object('success', true);
end $fn$;

create or replace function public.belonging_cancel(p_id bigint, p_note text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
begin
  perform public.belonging_assert_scope(p_id);
  if coalesce(btrim(coalesce(p_note,'')),'') = '' then
    raise exception 'سبب الإلغاء مطلوب' using errcode = '22023';
  end if;
  update customer_belongings
     set status='cancelled', closed_note=btrim(p_note),
         confirmed_at=now(), confirmed_by=public.belonging_actor()
   where id = p_id and status <> 'confirmed';
  if not found then raise exception 'تعذّر الإلغاء' using errcode = 'P0002'; end if;
  return jsonb_build_object('success', true);
end $fn$;

/* ── الطيار: «سلّمته» لازم تكون على متعلّق في نفس فرع الطلب ───
   الطيار مش مقصور بفرع في التوكن (التغطية بين الفروع)، فالحارس
   هنا على الطلب نفسه مش على المستخدم: ماينفعش يسلّم حاجة موجودة
   في فرع تاني. */
create or replace function public.belonging_mark_delivered(
  p_id bigint, p_order_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_st text; v_bid uuid; v_obid uuid;
begin
  if coalesce(public.jwt_app_role(),'') = '' then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  select status, branch_id into v_st, v_bid from customer_belongings where id = p_id;
  if v_st is null then raise exception 'المتعلّق غير موجود' using errcode = 'P0002'; end if;
  if v_st <> 'open' then
    raise exception 'المتعلّق ليس في حالة «معلّق»' using errcode = '22023';
  end if;
  if p_order_id is not null then
    select branch_id into v_obid from orders where id = p_order_id;
    if v_obid is distinct from v_bid then
      raise exception 'المتعلّق موجود في فرع آخر' using errcode = '42501';
    end if;
  end if;
  update customer_belongings
     set status='delivered_pending', delivered_at=now(),
         delivered_by=public.belonging_actor(), delivered_order_id=p_order_id
   where id = p_id;
  return jsonb_build_object('success', true);
end $fn$;

/* ── القراءة: الفرع بيتفرض، والبارامتر بيتجاهل لغير المصرّح ── */
create or replace function public.get_belongings(
  p_branch text default null, p_status text default null, p_search text default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_scope text := public.belonging_scope_code(); v_code text; v_out jsonb;
begin
  if v_scope = '__none__' then
    raise exception 'غير مصرّح: حسابك غير مربوط بفرع محدّد' using errcode = '42501';
  end if;
  v_code := coalesce(v_scope,
                     case when coalesce(btrim(coalesce(p_branch,'')),'') = '' then null
                          else public.branch_code_of(p_branch) end);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_out
    from (
      select cb.id, cb.cust_code, cb.customer_name, cb.customer_phone,
             b.name branch_name, cb.kind, cb.details, cb.status, cb.attempts,
             cb.last_attempt_at, cb.last_attempt_note,
             cb.created_at, cb.created_by,
             cb.delivered_at, cb.delivered_by, cb.confirmed_at, cb.confirmed_by, cb.closed_note,
             (extract(epoch from (now() - cb.created_at))/86400)::int days_open
        from customer_belongings cb
        left join branches b on b.id = cb.branch_id
       where (v_code is null or b.code = v_code)
         and (coalesce(btrim(coalesce(p_status,'')),'') = '' or cb.status = p_status)
         and (coalesce(btrim(coalesce(p_search,'')),'') = ''
              or cb.cust_code     ilike '%'||btrim(p_search)||'%'
              or cb.customer_name  ilike '%'||btrim(p_search)||'%'
              or cb.customer_phone ilike '%'||btrim(p_search)||'%'
              or cb.details        ilike '%'||btrim(p_search)||'%')
    ) x;
  return v_out;
end $fn$;

revoke all on function public.belonging_scope_code()         from public, anon;
revoke all on function public.belonging_assert_scope(bigint) from public, anon;
grant execute on function public.belonging_scope_code()         to authenticated;
grant execute on function public.belonging_assert_scope(bigint) to authenticated;
