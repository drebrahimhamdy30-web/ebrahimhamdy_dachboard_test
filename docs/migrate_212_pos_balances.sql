-- migrate_212_pos_balances.sql
--
-- جدول «أرصدة الحسابات: eplus مقابل الواقع» في شاشة الشيفت الحالي،
-- بديل شريط «الفيزا بالقنوات» وشريط المراجعة وجدول الملخّص (قرار المالك).
--
-- المصادر (كلها موجودة — مفيش مزامنة جديدة):
--   رصيد eplus   : eplus_safes (مهمة «أرصدة الخزائن» بتسحب F_Cash_Store
--                  للأربع فروع). كانت كل 1440 دقيقة — اترفعت لـ5 عشان
--                  الشاشة دي لحظية.
--   واقع المحافظ : آخر رصيد في رسالة المحفظة (wallet_sms.balance) — قرار
--                  المالك: من آخر رسالة مش من الرصيد الختامي المكتوب.
--   واقع الباقي  : pos_shift_lines.closing_balance (آخر سطر مكتوب).
--
-- الربط: اسم حساب eplus = method_key عندنا بعد تطبيع (مسافات/ى→ي/حالة).
-- الماكينات بتتربط دلوقتي (paymob1/2/3/4/5/7 · instapay · فورى 313).
-- أرقام المحافظ لأ، لأن eplus مسمّيها «vodafon cash» / «orange cash».
-- المالك هيعمل حساب في eplus لكل رقم — ساعتها الربط بيتم لوحده من غير
-- أي تعديل كود. الصفوف غير المربوطة بتظهر برصيد eplus فاضي، مش بتختفي.
--
-- ⚠️ ملاحظات على البيانات وقت البناء (2026-11-14):
--   • سان ستيفانو: كل حسابات eplus عنده active=0 وأسماؤها قديمة.
--   • المعمورة: eplus فيه «vodafon cash» واحد مقابل ٣ أرقام عندنا.
--   • الفجوة حقيقية: orange cash في eplus 0.79 والمحفظة فيها 82,000.

-- ═══ ١. الأرصدة تتحدّث كل ٥ دقايق بدل مرة في اليوم ═══
update public.sync_jobs
   set interval_minutes = 5, updated_at = now()
 where id = 'safes';

-- ═══ ٢. الدالة ═══
create or replace function public.get_pos_balances(p_branch text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_br text; v_role text; v_all boolean; v_out jsonb;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بعرض أرصدة الحسابات' using errcode = '42501';
  end if;

  v_role := public.jwt_app_role();
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') = 'service_role'
     or v_role = 'admin' then
    v_br := nullif(btrim(coalesce(p_branch,'')),'');
  else
    select pp.all_branches into v_all from page_permissions pp
     where pp.role = v_role and pp.page_key = 'current_shift';
    if coalesce(v_all,false) then v_br := nullif(btrim(coalesce(p_branch,'')),'');
    else v_br := coalesce(public.jwt_branch(), '__none__'); end if;
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
  /* واقع المحافظ = آخر رسالة فيها رصيد */
  wl as (
    select distinct on (branch, to_no) branch, to_no, balance, "createdAt" ts
      from wallet_sms
     where balance is not null and (v_br is null or branch = v_br)
     order by branch, to_no, "createdAt" desc
  ),
  /* واقع الباقي = آخر رصيد ختامي مكتوب في الشيفت */
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

revoke all on function public.get_pos_balances(text) from public;
revoke all on function public.get_pos_balances(text) from anon;
grant execute on function public.get_pos_balances(text) to authenticated, service_role;

notify pgrst, 'reload schema';
