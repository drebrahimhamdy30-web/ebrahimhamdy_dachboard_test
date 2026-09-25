-- ═══════════════════════════════════════════════════════════════════
-- أربع دوال فاتوا الفحص الأول — تلاتة منهم في شاشات «خلصت»
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- الفحص الأول كان على الشاشات (grep في HTML). الدوال دي مالهاش أثر في
-- كود الشاشة خالص — الشاشة بتنادي RPC والـRPC هو اللي بيحدّف الفرع.
-- فكل واحدة كانت «فشل صامت» كامل: الشاشة متحوّلة والبيانات مش بتوصل.
--
-- اللي اتكشف (بفحص pg_proc على أسماء/أكواد الفروع مش على الشاشات):
--
-- ① get_customers  →  customers.html
--    بترجّع balance · balance_san · balance_bishr **بس**. فعمود
--    السيوف اللي اتعمل في الشاشة كان بيفضل «—» لكل العملاء،
--    **والإجمالي كان ناقص** كذلك. فيه عميل واحد فعلًا له رصيد سيوف.
--
-- ② jard_uncounted  →  تقارير الجرد
--    `case p_branch when 'المعمورة' then m_q … end` بترجّع null لأي
--    فرع مش في الـcase، وبعدها `where has is true` بيرمي كل الصفوف.
--    يعني «الأصناف اللي ماتجردتش» للسيوف كانت **فاضية تمامًا** —
--    3,944 صنف مخفيين. ودي أخطرهم: قايمة فاضية في شاشة جرد تقرا
--    كأن كل حاجة اتجردت.
--
-- ③ get_branch_rep_users  →  إدارة المخزون + الحد الأدنى
--    `where branch in ('المعمورة','سان ستيفانو','سيدى بشر')`.
--    مندوب السيوف ماكانش بيرجع، فطلب التحويل بيتنسب لاسم الفرع
--    بدل حساب شخص.
--
-- ④ list_sales_months  →  طلبيات الأدوية
--    tot_mamora/tot_san/tot_bishr. الشاشة بتستعمل month و rows بس
--    فالإجماليات كانت ميتة — بقت كائن `totals` بالفرع.
--
-- التحقق على السحابة:
--   · get_customers: مفاتيح العميل بقت فيها balance_seyouf، وعميل
--     واحد له رصيد فعلي فيه.
--   · jard_uncounted('السيوف') = 3,944 بعد ما كانت 0.
--   · jard_uncounted('المعمورة') = 4,055 = **نفس المنطق القديم بالحرف**
--     (اتقارنت باستعلام مكتوب بنفس شروط الـcase القديمة).
--   · list_sales_months: totals فيها الأربعة.
--   · get_branch_rep_users: بترجّع كل فرع موجود في branch_users.
--
-- ⚠️ ملحوظة على ③: السيوف لسه مش في `branch_users` خالص، فالدالة
--   مش بترجّعه — ده **نقص بيانات مش نقص كود**. لازم يتضاف مستخدم
--   مندوب للفرع عشان طلبات التحويل تتنسب لشخص.
-- ═══════════════════════════════════════════════════════════════════

-- ① أرصدة العملاء: كل أعمدة الفروع
create or replace function public.get_customers()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_sel  text := '';
  v_col  text;
  v_rows jsonb;
  r      record;
begin
  for r in select * from public.branch_letters() loop
    -- ⚠️ تسمية قديمة غير منتظمة: المعمورة عمودها «balance» من غير لاحقة
    --    والباقي «balance_<code>». نفس القاعدة مكتوبة في balColOf()
    --    في customers.html — لازم يفضلوا متطابقين.
    v_col := case when r.code = 'mamora' then 'balance' else 'balance_' || r.code end;
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='customers' and column_name = v_col) then
      v_sel := v_sel || ', ' || quote_literal(v_col) || ', ' || quote_ident(v_col);
    else
      -- العمود ناقص → المفتاح بيرجع null. **مش** بنرجع لعمود فرع تاني:
      -- خانة فاضية ظاهرة أحسن من رصيد فرع منسوب لفرع غلط.
      v_sel := v_sel || ', ' || quote_literal(v_col) || ', null';
    end if;
  end loop;

  execute
    'select coalesce(jsonb_agg(jsonb_build_object('
    || '''cust_code'', cust_code, ''cust_name'', cust_name, ''type'', type,'
    || '''category'', category, ''note'', note' || v_sel
    || ')), ''[]''::jsonb) from public.customers'
    into v_rows;

  return v_rows;
end $fn$;

grant execute on function public.get_customers() to public, anon, authenticated;


-- ② الجرد: عمود الفرع من جدول الفروع بدل case مكتوبة
create or replace function public.jard_uncounted(p_branch text, p_from text, p_to text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_letter text;
  v_rows   jsonb;
begin
  select bl.letter into v_letter
    from public.branch_letters() bl
   where bl.code = public.branch_code_of(p_branch);

  -- فرع مش معروف أو مالوش حرف → فاضي، زي السلوك القديم لفرع مش في الـcase
  if v_letter is null then return '[]'::jsonb; end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='stock_flat'
                    and column_name = v_letter || '_q') then
    return '[]'::jsonb;
  end if;

  execute
       'with counted as ('
    || '  select distinct code from jard_audit_log'
    || '   where branch = $1'
    || '     and ($2 is null or $2 = '''' or (audited_at at time zone ''Africa/Cairo'') >= $2::timestamp)'
    || '     and ($3 is null or $3 = '''' or (audited_at at time zone ''Africa/Cairo'') <= $3::timestamp)'
    || '), inv as ('
    || '  select itm_code code, n name,'
    || '         ' || quote_ident(v_letter || '_q') || ' qty,'
    || '         ' || quote_ident(v_letter || '_h') || ' has'
    || '    from stock_flat'
    || ')'
    || ' select coalesce(jsonb_agg(jsonb_build_object('
    || '   ''code'', code, ''name'', name, ''qty'', qty) order by name), ''[]''::jsonb)'
    || '  from inv where has is true and coalesce(qty,0) <> 0'
    || '    and code not in (select code from counted)'
    into v_rows using p_branch, p_from, p_to;

  return v_rows;
end $fn$;


-- ③ مندوب كل فرع: القايمة من جدول الفروع (بالاسم أو اسم بديل)
create or replace function public.get_branch_rep_users()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(jsonb_object_agg(branch, username), '{}'::jsonb) from (
    select distinct on (bu.branch) bu.branch, bu.username
      from branch_users bu
     where bu.is_active
       and exists (
         select 1 from public.branches b, unnest(array[b.name] || coalesce(b.aliases,'{}'::text[])) nm
          where b.is_active
            and replace(nm,'ي','ى') = replace(btrim(bu.branch),'ي','ى'))
     order by bu.branch,
              case bu.role when 'employee' then 0 when 'manager' then 1 when 'inventory' then 2 else 9 end,
              bu.id
  ) t;
$fn$;

grant execute on function public.get_branch_rep_users() to public, anon, authenticated;


-- ④ قايمة الشهور: الإجماليات كائن بالفرع بدل تلات أعمدة ثابتة
drop function if exists public.list_sales_months();

create function public.list_sales_months()
returns table (month text, rows bigint, totals jsonb, last_upd timestamptz)
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_obj text := '';
  r     record;
begin
  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      v_obj := v_obj || case when v_obj = '' then '' else ', ' end
            || quote_literal(r.code) || ', sum(' || quote_ident(r.code) || ')';
    end if;
  end loop;

  return query execute
       'select month, count(*)::bigint,'
    || case when v_obj = '' then '''{}''::jsonb' else 'jsonb_build_object(' || v_obj || ')' end || ','
    || ' max(updated_at) from monthly_sales group by month order by month desc';
end $fn$;

grant execute on function public.list_sales_months() to public, anon, authenticated;

notify pgrst, 'reload schema';
