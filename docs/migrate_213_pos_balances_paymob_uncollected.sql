-- migrate_213_pos_balances_paymob_uncollected.sql
--
-- تصحيح مصدر «الواقع» في جدول أرصدة الحسابات.
--
-- الغلط: النسخة الأولى كانت بتاخد الواقع للماكينات من
-- pos_shift_lines.closing_balance. ده **مش رصيد** للماكينات —
-- شاشة إقفال الشيفت بتحسب الصافي كده:
--     ماكينة : net = closing            (الرقم المكتوب هو الصافي)
--     محفظة  : net = closing - opening + تحويلات
-- يعني الرقم المكتوب للماكينة هو **تحصيل الشيفت** مش رصيد تراكمي.
-- اتأكد بالبيانات: آخر شيفت معمورة — paymob1 المكتوب 7,178.00 =
-- مجموع حركات نفس الشيفت 7,178.00 بالظبط، وpaymob7 157.00 = 157.00.
-- فالفرق اللي كان معروض (+8,192 لـpaymob1) مكانش له معنى.
--
-- التصحيح (قرار المالك):
--   paymob*            → إجمالي المعاملات **غير المحصّلة**
--                        (wallet.done = false) لكل ماكينة.
--   المحافظ بالأرقام    → آخر رصيد في رسالة المحفظة (زي ما هو).
--   instapay · فورى     → فاضي، لأن مفيش ليهم مزامنة. بنزامن
--                        مبيعات باي موب بس حاليًا.
--
-- ⚠️ فخ: wallet.branch بيكتب «سيدي بشر» بالياء، وكل الجداول التانية
-- (pos_methods · wallet_sms · pos_shifts · branches) «سيدى بشر»
-- بالألف المقصورة. الربط بالفرع من غير تطبيع كان هيسقط ماكينتي
-- بشر بصمت. التطبيع replace(branch,'ى','ي') على الطرفين.

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
  pm_un as (
    select replace(w.branch,'ى','ي') bn, w.machine_name mk,
           sum(w.ammount) amt, max(w."createdAt") ts
      from wallet w
     where coalesce(w.done,false) = false
       and w.machine_name is not null
     group by replace(w.branch,'ى','ي'), w.machine_name
  ),
  j as (
    select a.branch, a.method_type, a.method_key, a.sort_order,
           coalesce(nullif(btrim(a.display_name),''), a.method_key) nm,
           e.name_ar e_name, e.balance e_bal, e.synced_at e_at,
           case when a.method_key ~ '^01[0-9]{9}$' then w.balance
                when a.method_key like 'paymob%'   then u.amt end r_bal,
           case when a.method_key ~ '^01[0-9]{9}$' and w.balance is not null then 'sms'
                when a.method_key like 'paymob%'   and u.amt     is not null then 'paymob' end r_src,
           case when a.method_key ~ '^01[0-9]{9}$' then w.ts
                when a.method_key like 'paymob%'   then u.ts end r_at
      from acc a
      left join es e on e.bc = public.branch_code_of(a.branch)
                    and e.n = lower(replace(replace(a.method_key,' ',''),'ى','ي'))
      left join wl w on w.branch = a.branch and w.to_no = a.method_key
      left join pm_un u on u.bn = replace(a.branch,'ى','ي') and u.mk = a.method_key
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
