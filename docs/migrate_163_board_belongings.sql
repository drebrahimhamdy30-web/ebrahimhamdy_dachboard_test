/* ════════════════════════════════════════════════════════════════
   متعلقات العميل على لوحة التوزيع وشاشة الطيار  (2026-10-27)
   ----------------------------------------------------------------
   `get_order_belongings(order_id)` بترجّع متعلقات طلب واحد — نداء
   لكل طلب على لوحة فيها مئات الكروت مش وارد. الدالة دي بترجّع
   خريطة `{ order_id: [متعلقات] }` لكل الطلبات النشطة في نداء واحد.

   ⚠️ المطابقة محسوبة على السيرفر بنفس شرط `get_order_belongings`
   (الكود أولًا والتليفون احتياطي) عشان ما يبقاش عندنا نسختين من
   المنطق — واحدة في القاعدة وواحدة في الجافاسكريبت تفرق عنها.

   `same_branch` بتقول هل المتعلّق في نفس فرع الطلب: الطيار
   مايقدرش يسلّم حاجة موجودة في فرع تاني، فبتظهر له تنبيه بلا زر.

   `p_order_ids` لشاشة الطيار: بتجيب متعلقات طلبات رحلته بس.
   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.get_board_belongings(
  p_branch uuid default null,
  p_order_ids uuid[] default null
) returns jsonb
language sql stable security definer set search_path = public
as $fn$
  select coalesce(jsonb_object_agg(x.order_id, x.arr), '{}'::jsonb)
    from (
      select o.id::text order_id,
             jsonb_agg(jsonb_build_object(
               'id',           cb.id,
               'kind',         cb.kind,
               'details',      cb.details,
               'attempts',     cb.attempts,
               'last_attempt_note', cb.last_attempt_note,
               'branch_name',  b.name,
               'same_branch',  (cb.branch_id is not distinct from o.branch_id),
               'created_at',   cb.created_at,
               'created_by',   cb.created_by
             ) order by cb.created_at) arr
        from orders o
        join customer_belongings cb
          on cb.status = 'open'
         and ( (coalesce(btrim(coalesce(o.cust_code,'')),'') <> ''
                and cb.cust_code = btrim(o.cust_code))
            or (coalesce(btrim(coalesce(cb.cust_code,'')),'') = ''
                and coalesce(btrim(coalesce(o.customer_phone,'')),'') <> ''
                and cb.customer_phone = btrim(o.customer_phone)) )
        left join branches b on b.id = cb.branch_id
       where (p_order_ids is not null and o.id = any(p_order_ids))
          or (p_order_ids is null
              and o.status in ('pending','postponed','assigned','picked')
              and (p_branch is null or o.branch_id = p_branch))
       group by o.id
    ) x;
$fn$;

revoke all on function public.get_board_belongings(uuid, uuid[]) from public, anon;
grant execute on function public.get_board_belongings(uuid, uuid[]) to authenticated;

/* ── تبويب «متعلقات العملاء» في شاشة العملاء ─────────────────
   صف في app_page_tabs بيخلّي التبويب يظهر في شاشة الصلاحيات،
   فالمالك يقدر يمنعه عن أي دور. غياب صف في tab_permissions =
   مسموح (`guardTabs` بتخفي اللي allowed=false بس). */
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order)
values ('customers','belongings','متعلقات العملاء','.tab-btn[data-tab="belongings"]', 4)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

/* الصيدلية هي اللي بتؤكّد استلام المتعلّق، ودور `pharmacist` مش
   مصرّح له بشاشة العملاء (أرصدة العملاء والموظفين). نفتحها له
   ونمنع عنه التبويبات التلاتة التانية — يشوف المتعلقات بس.
   ⚠️ `page_permissions.page` عمود NOT NULL (الاسم القديم بامتداد
   .html) فالصف بيتعدّل مش بيتضاف — إضافة بـpage_key لوحده بتفشل. */
update public.page_permissions
   set can_view = true
 where page_key = 'customers' and role = 'pharmacist';

insert into public.tab_permissions (page_key, tab_key, role, allowed)
values ('customers','search',     'pharmacist', false),
       ('customers','employees',  'pharmacist', false),
       ('customers','clients',    'pharmacist', false),
       ('customers','belongings', 'pharmacist', true)
on conflict (page_key, tab_key, role) do update set allowed = excluded.allowed;
