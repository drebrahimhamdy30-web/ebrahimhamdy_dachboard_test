-- migrate_212b_pos_balances_branch_key.sql
--
-- إصلاح: get_pos_balances كانت بترجّع «لا توجد حسابات مسجّلة لهذا الفرع».
--
-- السبب: شاشة تفاصيل الشيفت بتبعت **كود** الفرع (branches.sync_key
-- زي 'mamora') — زي ما بتعمل مع get_card_review، لأن
-- cashier_transactions.branch بيخزّن الكود. لكن الجداول اللي الدالة
-- الجديدة بتقراها (pos_methods · wallet_sms · pos_shifts) بتخزّن
-- **الاسم العربي**، فالمقارنة ماكانتش بتطابق ولا صف.
--
--   'mamora' → pos_methods.branch = 'mamora'  → 0 صف
--   'mamora' → بعد الحل → 'المعمورة'          → 9 صفوف
--
-- الحل: نحلّ اللي وصل لاسم عربي من جدول branches مهما كان شكله
-- (name أو sync_key أو code)، وبعدين نقارن بيه. eplus_safes بيفضل
-- بالكود عبر branch_code_of() زي ما هو.
--
-- ⚠️ الفخ ده عام: أي دالة جديدة تخلط جداول الكود (cashier_transactions
-- · eplus_safes) بجداول الاسم (pos_methods · wallet_sms · pos_shifts)
-- لازم تحلّ الفرع مرة واحدة في الأول.

create or replace function public.get_pos_balances(p_branch text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_in text; v_br text; v_role text; v_all boolean; v_out jsonb;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بعرض أرصدة الحسابات' using errcode = '42501';
  end if;

  v_role := public.jwt_app_role();
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
     or v_role = 'admin' then
    v_in := nullif(btrim(coalesce(p_branch,'')),'');
  else
    select pp.all_branches into v_all from page_permissions pp
     where pp.role = v_role and pp.page_key = 'current_shift';
    if coalesce(v_all,false) then v_in := nullif(btrim(coalesce(p_branch,'')),'');
    else v_in := coalesce(public.jwt_branch(), '__none__'); end if;
  end if;

  /* الشاشة بتبعت كود الفرع، والجداول دي بالاسم العربي — نحلّه. */
  if v_in is not null then
    select b.name into v_br from branches b
     where b.name = v_in or b.sync_key = v_in or b.code = v_in
     limit 1;
    v_br := coalesce(v_br, v_in);
  end if;

  with acc as (
    select pm.branch, pm.method_type, pm.method_key, pm.display_name, pm.sort_order
      from pos_methods pm
     where pm.is_active and (v_br is null or pm.branch = v_br)
  ),
  es as (
    select s.branch bc, s.name_ar, s.balance, s.synced_at,
           lower(replace(replace(coalesce(s.name_ar,''),' ',''),'ى','ي')) n
      from eplus_safes s
     where s.fcs_type = '3'
  ),
  wl as (
    select distinct on (branch, to_no) branch, to_no, balance, "createdAt" ts
      from wallet_sms
     where balance is not null and (v_br is null or branch = v_br)
     order by branch, to_no, "createdAt" desc
  ),
  sl as (
    select distinct on (sh.branch, l.method_key)
           sh.branch, l.method_key, l.closing_balance, l.created_at ts
      from pos_shift_lines l
      join pos_shifts sh on sh.id = l.shift_id
     where l.closing_balance is not null and (v_br is null or sh.branch = v_br)
     order by sh.branch, l.method_key, l.created_at desc
  ),
  j as (
    select a.branch, a.method_type, a.method_key, a.sort_order,
           coalesce(nullif(btrim(a.display_name),''), a.method_key) nm,
           e.name_ar e_name, e.balance e_bal, e.synced_at e_at,
           coalesce(w.balance, s.closing_balance) r_bal,
           case when w.balance is not null then 'sms'
                when s.closing_balance is not null then 'shift' end r_src,
           coalesce(w.ts, s.ts) r_at
      from acc a
      left join es e on e.bc = public.branch_code_of(a.branch)
                    and e.n = lower(replace(replace(a.method_key,' ',''),'ى','ي'))
      left join wl w on w.branch = a.branch and w.to_no  = a.method_key
      left join sl s on s.branch = a.branch and s.method_key = a.method_key
  )
  select jsonb_build_object(
    'branch',   v_br,
    'eplus_at', to_char(max(e_at) at time zone 'Africa/Cairo','MM-DD HH24:MI'),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'key',   method_key,
      'name',  nm,
      'type',  method_type,
      'enm',   e_name,
      'eplus', e_bal,
      'real',  r_bal,
      'src',   r_src,
      'at',    to_char(r_at at time zone 'Africa/Cairo','MM-DD HH24:MI'),
      'diff',  case when e_bal is not null and r_bal is not null
                    then round(r_bal - e_bal, 2) end
    ) order by method_type, sort_order nulls last, method_key), '[]'::jsonb)
  ) into v_out
  from j;

  return v_out;
end $fn$;

notify pgrst, 'reload schema';
