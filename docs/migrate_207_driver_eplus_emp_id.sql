-- ═══════════════════════════════════════════════════════════════════
--  كود الطيار في eplus (deliv_emp_id) — عمود + حفظه من شاشة الطيارين
-- ═══════════════════════════════════════════════════════════════════
--  ليه: عايزين نعدّل اسم مندوب التوصيل في فواتير eplus للطيار الحقيقي،
--  فمحتاجين خريطة طيار↔كود موظف eplus تتدار من الواجهة بدل SQL يدوي.
--  العمود `drivers.eplus_emp_id` بيمسك كود الموظف (Employee.e_id) اللي
--  هنكتبه في `sales_deliv_info.deliv_emp_id`. راجع [[delivery-rep-writeback]].
--
--  ⚠️ التوقيع بيتغيّر (بارامتر `p_eplus_emp_id` زيادة). `create or
--     replace` **مابيستبدلش** دالة بتوقيع مختلف — بيعمل نسخة تانية
--     جنبها و PostgREST يتلخبط بينهم (PGRST203). فالقديمة بتتشال صراحةً.
--
--  اتطبّق على السحابة (rxtjoqulmgkkcohmgzgi) بالفعل؛ الملف ده للذاتي
--  (supabase.ebrahimhamdy.com) — idempotent فينفع يتعاد.
-- ═══════════════════════════════════════════════════════════════════

alter table public.drivers add column if not exists eplus_emp_id bigint;

drop function if exists public.manager_upsert_driver(uuid,text,text,text,uuid,text,text,text,text,boolean,boolean,boolean,boolean,text[],text);

create or replace function public.manager_upsert_driver(
  p_driver_id uuid, p_full_name text, p_phone text, p_national_id text, p_branch_id uuid,
  p_username text, p_password text, p_vehicle_type text, p_vehicle_plate text,
  p_is_active boolean, p_is_online boolean, p_has_vehicle_license boolean, p_has_drive_license boolean,
  p_covered_types text[], p_email text default null, p_eplus_emp_id bigint default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public','extensions','pg_temp'
as $function$
declare
  branch_name text; bu_id int; new_driver_id uuid; v_email text;
begin
  perform public.require_app_role(array['admin','manager']);
  select name into branch_name from public.branches where id = p_branch_id;
  v_email := nullif(trim(p_email), '');

  if p_driver_id is null then
    if p_username is null or p_username = '' or p_password is null or p_password = '' then
      return jsonb_build_object('success', false, 'error', 'اسم المستخدم وكلمة المرور مطلوبان');
    end if;
    if exists (select 1 from public.branch_users where username = p_username) then
      return jsonb_build_object('success', false, 'error', 'اسم المستخدم "' || p_username || '" مستخدم بالفعل — اختر اسماً آخر');
    end if;
    if v_email is not null and exists (select 1 from public.branch_users where lower(email) = lower(v_email)) then
      return jsonb_build_object('success', false, 'error', 'الإيميل ده مستخدم بالفعل لمستخدم تاني');
    end if;
    insert into public.branch_users (username, password_hash, full_name, mobile, role, branch, is_active, email)
    values (p_username, crypt(p_password, gen_salt('bf')), p_full_name, p_phone, 'driver', branch_name, p_is_active, v_email)
    returning id into bu_id;
    begin
      insert into public.drivers (full_name, phone, national_id, branch_id, branch, branch_user_id,
        vehicle_type, vehicle_plate, is_active, is_online, has_vehicle_license, has_drive_license, covered_types, eplus_emp_id)
      values (p_full_name, p_phone, p_national_id, p_branch_id, branch_name, bu_id,
        p_vehicle_type, p_vehicle_plate, p_is_active, p_is_online, p_has_vehicle_license, p_has_drive_license, p_covered_types, p_eplus_emp_id)
      returning id into new_driver_id;
    exception when others then
      delete from public.branch_users where id = bu_id;
      return jsonb_build_object('success', false, 'error', 'فشل إنشاء الطيار: ' || SQLERRM);
    end;
    return jsonb_build_object('success', true, 'id', new_driver_id);
  else
    update public.drivers
    set full_name = p_full_name, phone = p_phone, national_id = p_national_id,
        branch_id = p_branch_id, branch = branch_name,
        vehicle_type = p_vehicle_type, vehicle_plate = p_vehicle_plate,
        is_active = p_is_active, is_online = p_is_online,
        has_vehicle_license = p_has_vehicle_license, has_drive_license = p_has_drive_license,
        covered_types = p_covered_types, eplus_emp_id = p_eplus_emp_id
    where id = p_driver_id
    returning branch_user_id into bu_id;
    if bu_id is not null then
      if v_email is not null and exists (select 1 from public.branch_users where lower(email) = lower(v_email) and id <> bu_id) then
        return jsonb_build_object('success', false, 'error', 'الإيميل ده مستخدم بالفعل لمستخدم تاني');
      end if;
      update public.branch_users
      set full_name = p_full_name, mobile = p_phone, branch = branch_name, is_active = p_is_active, email = v_email
      where id = bu_id;
    elsif p_username is not null and p_username <> '' and p_password is not null and p_password <> '' then
      if exists (select 1 from public.branch_users where username = p_username) then
        return jsonb_build_object('success', false, 'error', 'اسم المستخدم "' || p_username || '" مستخدم بالفعل — اختر اسماً آخر');
      end if;
      if v_email is not null and exists (select 1 from public.branch_users where lower(email) = lower(v_email)) then
        return jsonb_build_object('success', false, 'error', 'الإيميل ده مستخدم بالفعل لمستخدم تاني');
      end if;
      insert into public.branch_users (username, password_hash, full_name, mobile, role, branch, is_active, email)
      values (p_username, crypt(p_password, gen_salt('bf')), p_full_name, p_phone, 'driver', branch_name, p_is_active, v_email)
      returning id into bu_id;
      update public.drivers set branch_user_id = bu_id where id = p_driver_id;
    end if;
    return jsonb_build_object('success', true, 'id', p_driver_id);
  end if;
end $function$;

revoke all on function public.manager_upsert_driver(uuid,text,text,text,uuid,text,text,text,text,boolean,boolean,boolean,boolean,text[],text,bigint) from public;
grant execute on function public.manager_upsert_driver(uuid,text,text,text,uuid,text,text,text,text,boolean,boolean,boolean,boolean,text[],text,bigint) to authenticated, service_role;

notify pgrst, 'reload schema';
