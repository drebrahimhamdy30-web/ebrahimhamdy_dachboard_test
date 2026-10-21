/* ============================================================
   حفظ الصلاحيات كان بيرجّع 409 — تصحيح هدف التعارض
   ------------------------------------------------------------
   بعد ما migrate_149 ضاف القيد الفريد (page_key, role)، زرار «حفظ
   التغييرات» في شاشة الصلاحيات بقى يفشل بـ409 ومايتحفظش **ولا صف**.

   السبب: `save_page_permissions_bulk` بيعمل
   `on conflict (role, page)` — و`page` ده **اسم الملف**، مش هوية
   الصف. الصفوف الباقية لـ`seyouf_finance` كانت مخزّنة بـ
   `page = 'seyouf_finance'` (المفتاح) بينما `app_pages.file` =
   `'seyouf_finance.html'`. فالـinsert مالقاش تعارض على (role, page)،
   وحاول يدخل صف جديد، فضرب في القيد الجديد (page_key, role) → 409،
   والـstatement كله بيترجع فمفيش حاجة بتتحفظ.

   يعني القيد ما خلقش العيب — **كشف تضارب بيانات قديم**: نفس الصفحة
   مخزّنة بشكلين في عمود بيُستعمل كمفتاح.

   الإصلاح من جذره:
   ١) توحيد `page` على `app_pages.file` لكل الصفوف.
   ٢) `on conflict (page_key, role)` — الهوية الحقيقية للصف. المفتاح
      هو اللي الصلاحيات مربوطة بيه أصلًا (تغيير اسم ملف كان بيضيّع
      صلاحياته بصمت، ولذلك اتضاف page_key)، فاسم الملف يتكتب من
      الكتالوج ومايتقراش من المدخلات.
   ============================================================ */

/* ١) توحيد العمود (اتفحص قبلها: صفر تصادم مع (role, page)) */
update public.page_permissions pp
   set page = a.file
  from public.app_pages a
 where a.key = pp.page_key
   and pp.page is distinct from a.file;

/* ٢) الدالة بهدف تعارض صحيح */
create or replace function public.save_page_permissions_bulk(p_updates jsonb)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  u        jsonb;
  v_key    text;
  v_file   text;
begin
  perform public.require_app_role(array['admin']);
  for u in select value from jsonb_array_elements(p_updates) loop
    v_key  := nullif(u->>'page_key', '');
    v_file := nullif(u->>'page', '');

    if v_key is null and v_file is not null then
      select key into v_key from public.app_pages where file = v_file;
    end if;
    if v_key is null then continue; end if;          -- شاشة مش في الكتالوج

    /* اسم الملف **دايمًا** من الكتالوج مش من المدخلات — ده اللي كان
       بيخلّي العمود يتخزّن بشكلين مختلفين لنفس الصفحة. */
    select file into v_file from public.app_pages where key = v_key;
    if v_file is null then continue; end if;

    insert into public.page_permissions(role, page, page_key, can_view, can_edit)
    values (
      (u->>'role')::text, v_file, v_key,
      coalesce((u->>'can_view')::boolean, false),
      coalesce((u->>'can_edit')::boolean, false)
    )
    on conflict (page_key, role) do update
      set page     = excluded.page,
          can_view = excluded.can_view,
          can_edit = case when u ? 'can_edit' then (u->>'can_edit')::boolean
                          else public.page_permissions.can_edit end;
  end loop;
end;
$function$;
