-- ═══════════════════════════════════════════════════════════════════
-- المصروفات: مدير الفرع يشوف فرعه بس — بحراسة سيرفر حقيقية
-- ═══════════════════════════════════════════════════════════════════
-- الشاشة كانت مقفولة على الأدمن بحارس في المتصفح، والجدول مفتوح للقراءة
-- لأي مستخدم مسجّل — يعني الحارس شكلي: أي حد معاه توكن يقدر يقرا
-- مصروفات كل الفروع من برّه الشاشة.
--
-- دلوقتي:
--   • القراءة والكتابة بقت عبر دوال SECURITY DEFINER بتقرا الدور والفرع
--     من التوكن نفسه (jwt_app_role / jwt_branch) — مش من المتصفح.
--   • الأدمن: كل الفروع · مدير الفرع: فرعه بس · أي دور تاني: ممنوع.
--   • وسحبنا صلاحية القراءة/الكتابة المباشرة على الجدولين من anon
--     و authenticated، فالمسار الوحيد بقى الدوال دي.
--   ⚠️ مين يفتح الصفحة أصلًا لسه بيتحدد من شاشة الصلاحيات (page_permissions)
--     — ده تحكّم عرض؛ الحراسة الحقيقية للبيانات هنا في القاعدة.
--   ⚠️ n8n بيتصل بالقاعدة مباشرة (مش PostgREST) فمزامنة المصروفات
--     ماتأثرش بسحب الجرانت.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- فرع المستخدم بالاسم القياسي (أو null للأدمن/غير المعروف)
CREATE OR REPLACE FUNCTION public.exp_scope_branch()
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
declare
  v_role   text := coalesce(public.jwt_app_role(), '');
  v_branch text := coalesce(public.jwt_branch(), '');
  v_name   text;
  is_svc boolean := coalesce(current_setting('request.jwt.claims', true), '') = ''
                 or coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role'), '') = 'service_role';
begin
  if is_svc or v_role = 'admin' then
    return null;                      -- null = كل الفروع
  end if;
  if v_role <> 'manager' then
    raise exception 'غير مصرّح: شاشة المصروفات للأدمن ومدير الفرع فقط' using errcode = '42501';
  end if;
  select b.name into v_name from branches b
   where replace(b.name,'ي','ى') = replace(v_branch,'ي','ى')
      or v_branch = any(coalesce(b.aliases,'{}'::text[]))
   limit 1;
  if v_name is null then
    raise exception 'غير مصرّح: فرع المستخدم غير معروف (%)', v_branch using errcode = '42501';
  end if;
  return v_name;
end $fn$;

-- المصروفات + قواعد الإخفاء في نداء واحد، متفلترة بالفرع على السيرفر
CREATE OR REPLACE FUNCTION public.get_expenses()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
declare v_br text := public.exp_scope_branch();
begin
  return jsonb_build_object(
    'branch', v_br,                                   -- null = كل الفروع
    'expenses', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.doc_date desc)
        from erp_expenses e
       where v_br is null or e.branch = v_br), '[]'::jsonb),
    'rules', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at desc)
        from erp_expense_hide_rules r), '[]'::jsonb)
  );
end $fn$;

-- تعليم الحركة «تم» / التراجع — الفرع بيتقفل على السيرفر
CREATE OR REPLACE FUNCTION public.set_expense_seen(p_doc_code text, p_branch text, p_seen boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
declare v_br text := public.exp_scope_branch(); n int;
begin
  if v_br is not null and coalesce(p_branch,'') <> v_br then
    raise exception 'غير مصرّح: مسموح لك بمصروفات فرعك فقط' using errcode = '42501';
  end if;
  update erp_expenses
     set is_seen = coalesce(p_seen, true),
         seen_at = case when coalesce(p_seen, true) then now() else null end
   where doc_code = p_doc_code
     and branch  = p_branch
     and (v_br is null or branch = v_br);
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'rows', n);
end $fn$;

-- قواعد الإخفاء: إدارة الأدمن بس
CREATE OR REPLACE FUNCTION public.add_expense_hide_rule(p_field text, p_operator text, p_value text, p_label text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
declare v_id bigint;
begin
  perform public.require_app_role(array['admin']);
  insert into erp_expense_hide_rules (field, operator, value, label)
  values (p_field, p_operator, p_value, nullif(btrim(coalesce(p_label,'')),''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $fn$;

CREATE OR REPLACE FUNCTION public.del_expense_hide_rule(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $fn$
begin
  perform public.require_app_role(array['admin']);
  delete from erp_expense_hide_rules where id = p_id;
  return jsonb_build_object('ok', true);
end $fn$;

-- المسار الوحيد للبيانات بقى الدوال: نسحب القراءة/الكتابة المباشرة
REVOKE ALL ON public.erp_expenses            FROM anon, authenticated;
REVOKE ALL ON public.erp_expense_hide_rules  FROM anon, authenticated;

GRANT EXECUTE ON FUNCTION public.exp_scope_branch()                          TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_expenses()                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_expense_seen(text,text,boolean)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_expense_hide_rule(text,text,text,text)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.del_expense_hide_rule(bigint)               TO authenticated;

COMMIT;
