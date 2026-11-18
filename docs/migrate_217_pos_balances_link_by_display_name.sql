/* migrate_217 — ربط حساب eplus بالاسم المعروض كمان، مش بالمفتاح بس

   الليه: «فورى 6008» في المعمورة كان بيطلع «غير مربوط» رغم إن eplus
   عنده الخزنة بالظبط (fcs_id 15، رصيد 37,001 ج). السبب إن الربط كان
   على `pos_methods.method_key` لوحده، والمفتاح عندنا اتكتب **إنجليزي**
   `fawry6008` بينما eplus مسمّيها **عربي** «فورى 6008». جنبها «فورى 313»
   مربوطة لأن مفتاحها اتكتب عربي من الأساس — فالموضوع كان مصادفة في
   طريقة الكتابة مش قاعدة.

   التعديل: الربط بقى يجرّب **المفتاح ثم الاسم المعروض** (نفس التطبيع:
   حروف صغيرة · بلا مسافات · ى←ي). الأولوية للمفتاح عشان السلوك الحالي
   ما يتغيّرش، و`lateral ... limit 1` بدل `or` في الـon عشان ما يتكرّرش
   الصف لو الاتنين لقوا خزنتين.

   ⚠️ ماغيّرناش `method_key` نفسه عن قصد: المفتاح ده مكتوب في
   `pos_shift_lines` وسجلات قديمة، وتغييره كان هييتّم الصفوف دي.

   قياس الأثر قبل التطبيق (كل الفروع، الحسابات المفعّلة):
   · ربط جديد واحد بس — المعمورة fawry6008 ← «فورى 6008» (37,001 ج).
   · مفيش صف كان مربوط واتغيّر، ومفيش صف المفتاح والاسم بيوَدّوه
     لخزنتين مختلفتين.

   باقي غير المربوط بعد ده، والسبب إن eplus **مالوش** الخزنة دي أصلًا
   (مش مشكلة ربط):
   · السيوف: 01042604939 · «فورى 1»       (عنده «فورى 370» و«vodafon cash»)
   · سان:    paymob6                       (عنده «6 paymob» — اسم معكوس)
   · بشر:    01282512533 «ORANGE»           (عنده «orange cash» — حساب للشركة مش للرقم)
   دول بيتحلّوا من eplus نفسه بإعادة التسمية، زي ما القاعدة بتقول. */

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
     ⚠️ wallet.branch بيكتب «سيدي بشر» بالياء وباقي الجداول «سيدى بشر»
     بالألف المقصورة — لازم تطبيع وإلا ماكينات بشر تسقط بصمت. */
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
      /* المفتاح الأول وبعدين الاسم المعروض. lateral + limit 1 مقصود:
         `or` في الـon كان هيكرّر الصف لو كل واحد منهم لقى خزنة. */
      left join lateral (
        select x.name_ar, x.balance, x.synced_at
          from es x
         where x.bc = public.branch_code_of(a.branch)
           and x.n in (
                 lower(replace(replace(a.method_key,' ',''),'ى','ي')),
                 /* الاسم المعروض فاضي؟ يرجع للمفتاح — القيمة اللي فوق نفسها */
                 lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                a.method_key),' ',''),'ى','ي'))
               )
         order by (x.n = lower(replace(replace(a.method_key,' ',''),'ى','ي'))) desc
         limit 1
      ) e on true
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
end $function$;

comment on function public.get_pos_balances(text)
  is 'أرصدة الحسابات: eplus مقابل الواقع. الربط بخزنة eplus (fcs_type=3) بالاسم المطبّع — المفتاح method_key الأول، ولو مالقاش يجرّب display_name. مفيش عمود ربط عن قصد: لما eplus يتسمّى صح الربط يتم لوحده.';
