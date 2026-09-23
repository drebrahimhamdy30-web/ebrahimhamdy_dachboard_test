-- ═══════════════════════════════════════════════════════════════════
-- إخراج إعدادات الجرد و jard_erp من n8n للقاعدة مباشرة
-- ═══════════════════════════════════════════════════════════════════
-- (لسه ما اتطبّقش — طبّقه على السيرفر وبعدين علّم التاريخ هنا)
--
-- ليه:
--   • ويبهوكات jard_settings_manage و inventory_audit_erp مكانهاش
--     «تخزين في n8n» زي ما كنا فاكرين — n8n بيتصل بنفس قاعدة سوبابيز
--     بكريدنشيال Postgres مباشر وبينفّذ SQL. يعني الجداول هنا من الأصل،
--     وn8n مجرد طريق زيادة.
--   • الطريق ده بيتخطّى حماية سوبابيز بالكامل: allowedOrigins:"*" من
--     غير أي مصادقة، وبصلاحية كتابة مباشرة. أي حد يعرف الرابط يكتب.
--   • وفيه حقن SQL: العقد بتلصق نص من الرابط جوّه الاستعلام من غير تنظيف
--     (`values ('{{ $json.body.code }}')`).
--   • وعقدة حذف الأكواد السريعة معطوبة (operation غير صالحة) فالزرار
--     في الشاشة مش شغال أصلاً.
--
-- الحراسة هنا على السيرفر (نفس نمط submit_jard_audit — migrate_19):
--   • القراءة: أي حساب مسجّل دخول
--   • الإعدادات والأكواد السريعة: supervisor / admin بس
--   • تحديث نتيجة الجرد: inventory / supervisor / admin
--   • طلب صنف للجرد (insert): أي حساب مسجّل — ده بيتعمل من main.html
--   • الفرع بيتخزّن بالاسم القياسي من جدول branches (ى/ي والأسماء البديلة)
--
-- ملاحظة: الدوال دي مابتلمسش جداول المخزون (stock_mamora/san/bishr)
--         فهي مستقلة تمامًا عن شغل توحيد المخزون.
-- ═══════════════════════════════════════════════════════════════════

-- ── مساعد: اسم الفرع القياسي ─────────────────────────────────────
create or replace function public.jard_canon_branch(p_branch text)
returns text
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select b.name
    from branches b
   where replace(b.name, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى')
      or exists (select 1 from unnest(coalesce(b.aliases, '{}')) a
                  where replace(a, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى'))
   limit 1;
$fn$;

revoke all on function public.jard_canon_branch(text) from public, anon;
grant execute on function public.jard_canon_branch(text) to authenticated, service_role;


-- ═══ ١) إعدادات الجرد ═══════════════════════════════════════════

-- بترجّع jsonb array مش returns table: أنواع أعمدة الجدول مش متأكد منها
-- (الترحيل ده اتكتب من قراءة عقد n8n)، وأي فرق في النوع مع returns table
-- بيرمي خطأ وقت النداء. الـjsonb بيشيل الافتراض ده خالص.
create or replace function public.get_jard_settings()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]'::jsonb)
    from (select s.id, s.category, s.keywords_ar, s.keywords_en,
                 s.min_price, s.cycle_days, s.sort_order
            from jard_settings s) t;
$fn$;

revoke all on function public.get_jard_settings() from public, anon;
grant execute on function public.get_jard_settings() to authenticated, service_role;


-- التعديل: مشرف الجرد والأدمن بس.
-- ⚠️ الكلمات بتتمرّر كـtext[] مش نص — فمفيش لصق SQL زي ما كان في n8n.
create or replace function public.update_jard_settings(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  app_role text  := public.jwt_app_role();
  v_cat    text  := btrim(coalesce(p ->> 'category', ''));
  v_cycle  integer;
  v_min    numeric;
  v_ar     text[];
  v_en     text[];
  r        jard_settings%rowtype;
begin
  if pg_role <> 'service_role' and coalesce(app_role, '') not in ('supervisor', 'admin') then
    return jsonb_build_object('success', false, 'error', 'تعديل إعدادات الجرد لمشرف الجرد والأدمن بس');
  end if;

  if v_cat = '' then
    return jsonb_build_object('success', false, 'error', 'الفئة ناقصة');
  end if;

  -- المصفوفات بتيجي كـJSON array؛ أي حاجة تانية تتعامل كفاضية
  v_ar := case when jsonb_typeof(p -> 'keywords_ar') = 'array'
               then array(select jsonb_array_elements_text(p -> 'keywords_ar')) end;
  v_en := case when jsonb_typeof(p -> 'keywords_en') = 'array'
               then array(select jsonb_array_elements_text(p -> 'keywords_en')) end;

  v_min   := case when (p ->> 'min_price')  ~ '^-?[0-9]+(\.[0-9]+)?$' then (p ->> 'min_price')::numeric end;
  v_cycle := case when (p ->> 'cycle_days') ~ '^[0-9]+$'              then (p ->> 'cycle_days')::integer else 7 end;

  update jard_settings
     set keywords_ar = coalesce(v_ar, '{}'::text[]),
         keywords_en = coalesce(v_en, '{}'::text[]),
         -- الشاشة بتبعت min_price لفئة «غوالى» بس — فلو المفتاح مش مبعوت
         -- نسيب القيمة زي ما هي بدل ما نمسحها
         min_price   = case when p ? 'min_price' then v_min else min_price end,
         cycle_days  = v_cycle,
         updated_at  = now()
   where category = v_cat
  returning * into r;

  if not found then
    return jsonb_build_object('success', false, 'error', 'فئة غير معروفة: ' || v_cat);
  end if;

  return jsonb_build_object('success', true, 'row', to_jsonb(r));
end $fn$;

revoke all on function public.update_jard_settings(jsonb) from public, anon;
grant execute on function public.update_jard_settings(jsonb) to authenticated, service_role;


-- ═══ ٢) الأكواد سريعة الحركة ════════════════════════════════════

create or replace function public.get_jard_fastmove()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.added_at desc), '[]'::jsonb)
    from (select f.id, f.code, f.added_at from jard_fastmove_codes f) t;
$fn$;

revoke all on function public.get_jard_fastmove() from public, anon;
grant execute on function public.get_jard_fastmove() to authenticated, service_role;


create or replace function public.add_jard_fastmove(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  app_role text  := public.jwt_app_role();
  v_code   text  := btrim(coalesce(p_code, ''));
  r        jard_fastmove_codes%rowtype;
begin
  if pg_role <> 'service_role' and coalesce(app_role, '') not in ('supervisor', 'admin') then
    return jsonb_build_object('success', false, 'error', 'إضافة كود سريع الحركة لمشرف الجرد والأدمن بس');
  end if;

  if v_code = '' then
    return jsonb_build_object('success', false, 'error', 'الكود ناقص');
  end if;

  insert into jard_fastmove_codes (code) values (v_code)
  on conflict (code) do nothing
  returning * into r;

  if r.id is null then
    return jsonb_build_object('success', false, 'error', 'الكود موجود قبل كده');
  end if;

  return jsonb_build_object('success', true, 'row', to_jsonb(r));
end $fn$;

revoke all on function public.add_jard_fastmove(text) from public, anon;
grant execute on function public.add_jard_fastmove(text) to authenticated, service_role;


-- ⚠️ ده بديل عقدة Delete Fastmove Code المعطوبة في n8n: هي operation
--    غير صالحة فالحذف مكانش بيشتغل خالص (27 كود بـid 1..27 بلا فجوات).
--    وهنا الحذف مربوط بـid واحد بعينه — مستحيل يمسح الجدول.
create or replace function public.delete_jard_fastmove(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  app_role text  := public.jwt_app_role();
  v_n      integer;
begin
  if pg_role <> 'service_role' and coalesce(app_role, '') not in ('supervisor', 'admin') then
    return jsonb_build_object('success', false, 'error', 'حذف كود سريع الحركة لمشرف الجرد والأدمن بس');
  end if;

  if p_id is null then
    return jsonb_build_object('success', false, 'error', 'رقم الكود ناقص');
  end if;

  delete from jard_fastmove_codes where id = p_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    return jsonb_build_object('success', false, 'error', 'الكود مش موجود');
  end if;

  return jsonb_build_object('success', true, 'deleted', v_n);
end $fn$;

revoke all on function public.delete_jard_fastmove(bigint) from public, anon;
grant execute on function public.delete_jard_fastmove(bigint) to authenticated, service_role;


-- ═══ ٣) صفوف الجرد (jard_erp) ═══════════════════════════════════

-- نفس أعمدة استعلام n8n بالحرف (bill_date بتترجع باسم time زي ما الشاشة
-- متوقعة). jsonb مش returns table لنفس سبب get_jard_settings فوق.
create or replace function public.get_jard_erp()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]'::jsonb)
    from (select e.id, e.code, e.branch, e.type, e.itm_name_ar, e.itm_name_en,
                 e.bill_no, e.bill_date as "time", e.qty, e.sell_price,
                 e.unit_ar, e.unit_en, e.skip, e.done, e.mismatch,
                 e.actual_balance, e.system_balance, e.action_time
            from jard_erp e) t;
$fn$;

revoke all on function public.get_jard_erp() from public, anon;
grant execute on function public.get_jard_erp() to authenticated, service_role;


-- طلب صنف للجرد — بيتعمل من main.html، فمتاح لأي حساب مسجّل
create or replace function public.insert_jard_erp(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role text  := coalesce(claims ->> 'role', '');
  v_code  text  := btrim(coalesce(p ->> 'item_code', ''));
  v_br    text  := btrim(coalesce(p ->> 'target_branch', ''));
  v_canon text;
  r       jard_erp%rowtype;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return jsonb_build_object('success', false, 'error', 'لازم تسجيل دخول');
  end if;

  if v_code = '' or v_br = '' then
    return jsonb_build_object('success', false, 'error', 'الكود أو الفرع ناقص');
  end if;

  v_canon := public.jard_canon_branch(v_br);
  if v_canon is null then
    return jsonb_build_object('success', false, 'error', 'فرع غير معروف: ' || v_br);
  end if;

  insert into jard_erp (code, branch, type, itm_name_ar, itm_name_en)
  values (v_code, v_canon, 'erp',
          nullif(p ->> 'item_name_ar', ''), nullif(p ->> 'item_name_en', ''))
  returning * into r;

  return jsonb_build_object('success', true, 'id', r.id, 'row', to_jsonb(r));
end $fn$;

revoke all on function public.insert_jard_erp(jsonb) from public, anon;
grant execute on function public.insert_jard_erp(jsonb) to authenticated, service_role;


-- تسجيل نتيجة الجرد على صف موجود — لموظف/مشرف الجرد والأدمن
create or replace function public.update_jard_erp(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  app_role text  := public.jwt_app_role();
  v_id     bigint;
  r        jard_erp%rowtype;
begin
  if pg_role <> 'service_role' and coalesce(app_role, '') not in ('inventory', 'supervisor', 'admin') then
    return jsonb_build_object('success', false, 'error', 'تسجيل نتيجة الجرد لموظف/مشرف الجرد بس');
  end if;

  v_id := case when (p ->> 'id') ~ '^[0-9]+$' then (p ->> 'id')::bigint end;
  if v_id is null then
    return jsonb_build_object('success', false, 'error', 'رقم الصف ناقص أو غير صالح');
  end if;

  update jard_erp
     set skip           = coalesce((p ->> 'skip')::boolean, skip),
         done           = coalesce((p ->> 'done')::boolean, done),
         mismatch       = coalesce((p ->> 'mismatch')::boolean, mismatch),
         actual_balance = coalesce(nullif(p ->> 'actual_balance', ''), actual_balance),
         system_balance = coalesce(
           case when (p ->> 'system_balance') ~ '^-?[0-9]+(\.[0-9]+)?$'
                then (p ->> 'system_balance')::numeric end, system_balance),
         action_time    = coalesce(nullif(p ->> 'action_time', ''), to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF')),
         updated_at     = now()
   where id = v_id
  returning * into r;

  if not found then
    return jsonb_build_object('success', false, 'error', 'الصف مش موجود');
  end if;

  return jsonb_build_object('success', true, 'row', to_jsonb(r));
end $fn$;

revoke all on function public.update_jard_erp(jsonb) from public, anon;
grant execute on function public.update_jard_erp(jsonb) to authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- بعد التطبيق والتأكد من الشاشات:
--   • عطّل عقدتَي الويبهوك في n8n: Webhook1 + Webhook GET (inventory_audit_erp)
--     و Webhook4 (jard_settings_manage)
--   • ⚠️ ماتعطّلش الورك فلو كله — فيه get_balance وهو حيّ ومستخدم
-- ═══════════════════════════════════════════════════════════════════
