/* migrate_229 — ربط صريح بين حساب «طرق الدفع» وخزنة eplus

   ⚠️ تصحيح لخطة قلتها قبل كده: كنت ناوي أستعمل `wallet_channel_map`،
   بس مفتاحها **اسم القناة على الفاتورة** مش حساب «طرق الدفع» — محور
   مختلف. استعمالها كان هيرجّعنا لمطابقة الأسماء من تاني. الربط الصح
   مكانه `pos_methods` نفسه.

   الليه: شاشة الأرصدة بتخمّن خزنة eplus **بالاسم**، والأسماء بتتغيّر.
   ٣ حوادث لحد دلوقتي:
     · «فورى 6008» إنجليزي عندنا وعربي في eplus (migrate_217)
     · «paymob 6» اتقلب لـ«6 paymob» في eplus
     · «ORANGE» عندنا و«orange cash» في eplus (migrate_226)
   كل مرة الحساب بيختفي من المقارنة في صمت لحد ما حد يلاحظ.

   الحل: عمود `pos_methods.eplus_fcs_id` — **رقم** الخزنة، ثابت في
   eplus مهما الاسم اتغيّر. الدالة بتستعمله أولًا، والتخمين بالاسم
   بيفضل احتياطي للحسابات اللي لسه ما حدش ربطها.

   التعبئة الأولى من الربط الشغّال والمتأكَّد منه دلوقتي: ١٧ من ١٩
   حساب. الاتنين الباقيين (السيوف 01042604939 و«فورى 1») eplus مالوش
   خزنة ليهم أصلًا فبيفضلوا فاضيين — وده صح.

   ملحوظة: التخمين بالاسم مقصور على خزائن fcs_type='3' (القنوات
   الإلكترونية) عشان مايصطادش خزنة كاش بنفس الاسم. الربط الصريح مش
   مقيّد بده — لو حد ربط عن قصد بخزنة من نوع تاني، تُحترم.

   النص مبني على نسخة السحابة الشغّالة (migrate_226). */

alter table public.pos_methods
  add column if not exists eplus_fcs_id integer;

comment on column public.pos_methods.eplus_fcs_id is
  'رقم خزنة eplus المربوطة بالحساب ده. ثابت مهما الاسم اتغيّر — الأولوية ليه على التخمين بالاسم في get_pos_balances.';

/* تعبئة أولى من الربط الحالي المتأكَّد منه. بتتنفّذ مرة واحدة
   (where eplus_fcs_id is null) فإعادة التشغيل مابتدوسش على ربط يدوي. */
update public.pos_methods pm
   set eplus_fcs_id = m.fcs_id
  from (
    select a.id,
           (select s.fcs_id from eplus_safes s
             where s.branch = public.branch_code_of(a.branch)
               and s.fcs_type = '3'
               and lower(replace(replace(coalesce(s.name_ar,''),' ',''),'ى','ي')) in (
                     lower(replace(replace(a.method_key,' ',''),'ى','ي')),
                     lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                    a.method_key),' ',''),'ى','ي')),
                     lower(replace(replace(a.method_key,' ',''),'ى','ي')) || 'cash',
                     lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                    a.method_key),' ',''),'ى','ي')) || 'cash')
             order by (lower(replace(replace(coalesce(s.name_ar,''),' ',''),'ى','ي'))
                       = lower(replace(replace(a.method_key,' ',''),'ى','ي'))) desc
             limit 1) as fcs_id
      from public.pos_methods a
     where a.is_active
  ) m
 where pm.id = m.id and m.fcs_id is not null and pm.eplus_fcs_id is null;

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
    select pm.branch, pm.method_type, pm.method_key, pm.display_name, pm.sort_order,
           pm.eplus_fcs_id
      from pos_methods pm
     where pm.is_active and (v_br is null or pm.branch = v_br)
  ),
  es as (
    select s.branch bc, s.fcs_id, s.fcs_type ft, s.name_ar, s.balance, s.synced_at,
           lower(replace(replace(coalesce(s.name_ar,''),' ',''),'ى','ي')) n
      from eplus_safes s
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
           /* 🔑 الربط الصريح أولًا: رقم الخزنة ثابت في eplus مهما الاسم
              اتغيّر. التخمين بالاسم بقى احتياطي للحسابات اللي لسه ما
              حدش ربطها — ومقصور على fcs_type='3' عشان مايصطادش خزنة
              كاش بنفس الاسم. */
           and case when a.eplus_fcs_id is not null then x.fcs_id = a.eplus_fcs_id
                    else x.ft = '3' and x.n in (
                           lower(replace(replace(a.method_key,' ',''),'ى','ي')),
                           lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                          a.method_key),' ',''),'ى','ي')),
                           /* eplus بيسمّي محفظة الشركة «orange cash» واحنا
                              مسجّلينها بالرقم واسمها «ORANGE» — فرق كلمة. */
                           lower(replace(replace(a.method_key,' ',''),'ى','ي')) || 'cash',
                           lower(replace(replace(coalesce(nullif(btrim(a.display_name),''),
                                                          a.method_key),' ',''),'ى','ي')) || 'cash'
                         )
               end
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
  is 'أرصدة الحسابات: eplus مقابل الواقع. الربط بخزنة eplus من pos_methods.eplus_fcs_id (رقم ثابت) أولًا، ولو فاضي يخمّن بالاسم المطبّع (المفتاح ثم display_name ثم نفس الاسم + «cash») بين خزائن fcs_type=3 بس.';
