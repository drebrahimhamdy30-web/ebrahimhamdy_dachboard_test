/* ============================================================
   نطاق الفروع لكل دور — يتظبط من شاشة الصلاحيات
   ------------------------------------------------------------
   خيارين بس بقرار المالك: «كل الفروع» أو «فرعه بس».
   مفيش صف للدور = فرعه بس (الافتراضي الآمن).

   الأدمن مستثنى في الكود نفسه: بيرجع «كل الفروع» قبل ما يبص على
   الجدول أصلًا، وsave_role_branch_scope بتجبر صفّه على true بعد أي
   حفظ — عشان ماينفعش حد يقفل على نفسه الوصول بالغلط.

   الحارس purchase_branch_scope بيتجاهل الفرع اللي العميل بعته لو
   الدور مش «كل الفروع» — فتعديل الـselect من المتصفح مابيفيدش.
   ============================================================ */
create table if not exists public.role_branch_scope (
  role         text primary key,
  all_branches boolean not null default false,
  updated_at   timestamptz not null default now(),
  updated_by   text
);

insert into public.role_branch_scope(role, all_branches) values ('admin', true)
on conflict (role) do nothing;

revoke all on table public.role_branch_scope from public, anon;
grant select on table public.role_branch_scope to authenticated;

create or replace function public.save_role_branch_scope(p_updates jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare n integer := 0;
begin
  perform require_app_role(array['admin']);

  insert into role_branch_scope(role, all_branches, updated_at, updated_by)
  select u->>'role',
         coalesce((u->>'all_branches')::boolean, false),
         now(),
         coalesce(jwt_app_role(), '?')
    from jsonb_array_elements(coalesce(p_updates, '[]'::jsonb)) u
   where coalesce(u->>'role', '') <> ''
  on conflict (role) do update
     set all_branches = excluded.all_branches,
         updated_at   = now(),
         updated_by   = excluded.updated_by;
  get diagnostics n = row_count;

  update role_branch_scope set all_branches = true where role = 'admin';
  return n;
end
$fn$;

revoke all on function public.save_role_branch_scope(jsonb) from public, anon;
grant execute on function public.save_role_branch_scope(jsonb) to authenticated;

create or replace function public.purchase_branch_scope(p_branch text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := jwt_app_role();
  v_br   text := jwt_branch();
  v_all  boolean;
  v_code text;
begin
  if v_role is null then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;

  if v_role = 'admin' then
    return nullif(btrim(coalesce(p_branch, '')), '');   -- فاضي = كل الفروع
  end if;

  select all_branches into v_all from role_branch_scope where role = v_role;
  if coalesce(v_all, false) then
    return nullif(btrim(coalesce(p_branch, '')), '');
  end if;

  /* ⚠️ الفرع في التوكن اسم عربي («المعمورة») مش كود («mamora») */
  select b.code into v_code
    from branches b
   where b.name = v_br or v_br = any(coalesce(b.aliases, '{}'::text[]))
   limit 1;

  if v_code is null then
    raise exception 'حسابك غير مربوط بفرع محدّد — يُرجى مراجعة إدارة المستخدمين'
      using errcode = '42501';
  end if;
  return v_code;
end
$fn$;

revoke all on function public.purchase_branch_scope(text) from public, anon;
grant execute on function public.purchase_branch_scope(text) to authenticated;

notify pgrst, 'reload schema';
