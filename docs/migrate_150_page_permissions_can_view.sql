/* ============================================================
   صلاحيات الصفحات: can_view هو الفحص الحقيقي — مش وجود الصف
   ------------------------------------------------------------
   «مطابقة خزنة visa» كانت مسجّلة صح في app_pages وصفوف صلاحياتها
   موجودة للأدوار التلاتة، ومع ذلك مابتظهرش في القائمة لأي حد.

   السبب: `insert into page_permissions (page_key, role)` بيسيب
   **can_view = false** (القيمة الافتراضية)، والقائمة بتقرا من
   `get_role_pages` اللي بيفلتر على can_view. يعني الصف موجود
   وبيدّي **صفر** صلاحية — تسجيل ناجح بلا أي أثر.

   الفحص: من كل الصفحات النشطة، visa_recon هي **الوحيدة** اللي
   مفيش دور واحد عندها can_view (٣ صفوف، صفر مُشاهد).

   ١) إصلاح الصفوف.
   ٢) إصلاح جذري: دالة تسجيل تضبط can_view بنفسها، عشان أي شاشة
      جاية ما تتعرّضش لنفس الفشل الصامت. أي ترحيل جديد ينادي
      `register_page_roles(...)` بدل الـinsert الخام.
   ============================================================ */

create or replace function public.register_page_roles(
  p_page_key     text,
  p_view_roles   text[],
  p_edit_roles   text[] default '{}',
  p_all_branches text[] default '{}'
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  insert into page_permissions (page_key, page, role, can_view, can_edit, all_branches)
  select p_page_key,
         coalesce((select file from app_pages where key = p_page_key), p_page_key),
         r,
         true,
         r = any(p_edit_roles),
         r = any(p_all_branches)
    from unnest(p_view_roles) r
  on conflict (page_key, role) do update
    set can_view     = true,
        can_edit     = excluded.can_edit     or page_permissions.can_edit,
        all_branches = excluded.all_branches or page_permissions.all_branches;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function public.register_page_roles(text, text[], text[], text[]) from public, anon;

/* إصلاح الشاشة المتأثرة — نفس نية migrate_148 بس فعّالة هذه المرة */
select public.register_page_roles(
  'visa_recon',
  array['admin','manager','accountant'],
  array['admin'],
  array['admin','manager','accountant']   -- الشاشة بتعرض كل الفروع بطبيعتها
);
