/* migrate_226 — ربط حساب المحفظة لما eplus بيزوّد كلمة «cash»

   بلاغ المالك 2026-11-22: ORANGE في سيدي بشر «غير مربوط».
   السبب: عندنا الحساب مسجّل بالرقم 01282512533 واسمه المعروض «ORANGE»،
   وeplus مسمّيه «orange cash». الربط بيجرّب المفتاح ثم الاسم المعروض
   بعد تطبيع (حروف صغيرة · بلا مسافات · ى←ي) — ومفيش واحد فيهم بيساوي
   «orangecash». الفرق **كلمة واحدة**.

   الإضافة: مرشّح تالت = الاسم المطبّع + 'cash'.

   قياس قبل التطبيق على كل الفروع (١٩ حساب مفعّل): بيربط **حساب واحد بس**
   — بشر 01282512533 ← «orange cash». مفيش ربط قائم اتغيّر ومفيش صف اتكرّر.
   واللاحقة محدّدة بالظبط ('cash') عن قصد عشان ما تقربش من حالات زي
   «فورى 6008» و«فورى 6064».

   بعد التطبيق: بشر ORANGE → eplus ٧٦٩ · الواقع ١٢٬٠٨٧ · الفرق +١١٬٣١٨
   (الفجوة المعتادة: الصرف مش متسجّل في eplus).
   الباقي غير مربوط: السيوف 01042604939 و«فورى 1» — eplus مالوش خزنة
   ليهم أصلًا، مش مشكلة ربط.

   ⚠️ النص ده ماخوذ من نسخة السحابة الشغّالة بعد التعديل. الدالة كانت
   اتغيّرت قبل كده من جلسة تانية (تطبيع اسم الماكينة في pm_un) فملف
   migrate_217 مابقاش هو المرجع. */

CREATE OR REPLACE FUNCTION public.get_pos_balances(p_branch text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  /* المحافظ: آخر رسالة فيها رصيد */
  wl as (
    select distinct on (branch, to_no) branch, to_no, balance, "createdAt" ts
      from wallet_sms
     where balance is not null and (v_br is null or branch = v_br)
     order by branch, to_no, "createdAt" desc
  ),
  /* باي موب: إجمالي المعاملات غير المحصّلة (done = false) لكل ماكينة.
     ⚠️ الربط بالاسم المُطبَّع (شيل المسافات + ى→ي) عشان اختلاف
     المسافة/الياء بين طرق الدفع وجدول wallet مايكسرش الربط. */
  pm_un as (
    select replace(w.branch,'ى','ي') bn,
           lower(replace(replace(w.machine_name,' ',''),'ى','ي')) mkn,
           sum(w.ammount) amt, max(w."createdAt") ts
      from wallet w
     where coalesce(w.done,false) = false
       and w.machine_name is not null
     group by replace(w.branch,'ى','ي'),
              lower(replace(replace(w.machine_name,' ',''),'ى','ي'))
  ),
  j as (
    select a.branch, a.method_type, a.method_key, a.sort_order,
           coalesce(nullif(btrim(a.display_name),''), a.method_key) nm,
           e.name_ar e_name, e.balance e_bal, e.synced_at e_at,
           case when a.method_key ~ '^01[0-9]{9}$' then w.balance
                when lower(replace(a.method_key,' ','')) like 'paymob%' then u.amt end r_bal,
           case when a.method_key ~ '^01[0-9]{9}$' and w.balance is not null then 'sms'
                when lower(replace(a.method_key,' ','')) like 'paymob%' and u.amt is not null then 'paymob' end r_src,
           case when a.method_key ~ '^01[0-9]{9}$' then w.ts
                when lower(replace(a.method_key,' ','')) like 'paymob%' then u.ts end r_at
      from acc a
      left join lateral (
        select x.name_ar, x.balance, x.synced_at
          from es x
         where x.bc = public.branch_code_of(a.branch)
           and x.n in (
                 lower(replace(replace(a.method_key,' ',''),'ى','ي')),
                 lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                a.method_key),' ',''),'ى','ي')),
                 /* eplus بيسمّي حساب المحفظة باسم الشركة + cash («orange cash»)
                    واحنا مسجّلينه بالرقم واسمه المعروض «ORANGE» — الفرق كلمة
                    واحدة. اللاحقة محدّدة بالظبط عشان ما نقربش من «فورى 6008»
                    و«فورى 6064». القياس: بتربط حساب واحد بس في كل الفروع. */
                 lower(replace(replace(a.method_key,' ',''),'ى','ي')) || 'cash',
                 lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                a.method_key),' ',''),'ى','ي')) || 'cash'
               )
         /* الأولوية: المفتاح بالظبط، ثم الاسم المعروض بالظبط، وبعدين +cash */
         order by (x.n = lower(replace(replace(a.method_key,' ',''),'ى','ي'))) desc,
                  (x.n = lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                 a.method_key),' ',''),'ى','ي'))) desc
         limit 1
      ) e on true
      left join wl w on w.branch = a.branch and w.to_no = a.method_key
      left join pm_un u on u.bn = replace(a.branch,'ى','ي')
                       and u.mkn = lower(replace(replace(a.method_key,' ',''),'ى','ي'))
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
end $function$;

comment on function public.get_pos_balances(text)
  is 'أرصدة الحسابات: eplus مقابل الواقع. الربط بخزنة eplus (fcs_type=3) بالاسم المطبّع — المفتاح method_key الأول، ثم display_name، وأخيرًا نفس الاسم + «cash» (eplus بيسمّي محفظة الشركة «orange cash»). مفيش عمود ربط عن قصد: لما eplus يتسمّى صح الربط يتم لوحده.';
