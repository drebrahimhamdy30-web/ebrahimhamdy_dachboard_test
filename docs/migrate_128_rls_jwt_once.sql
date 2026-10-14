/* ============================================================
   حارس الصلاحيات: دوال التوكن تتحسب مرة واحدة بدل كل صف
   ------------------------------------------------------------
   jwt_app_role() / jwt_all_branches() / jwt_branch_id() كلها STABLE،
   بس لما بتتكتب كده جوّه سياسة RLS، بوستجرس بيناديها **لكل صف**
   على حدة — ومعاها تحليل JSON للتوكن في كل مرة. على جدول حضور
   الطيارين (٦ آلاف صف) ده كان بيوصل لـ257 مللي للنداء الواحد.

   لفّها في (select ...) بيحوّلها لـInitPlan: بوستجرس بيحسبها **مرة
   واحدة** في أول الاستعلام ويستعمل الناتج كثابت لكل الصفوف. نفس
   النتيجة بالضبط — القيمة مابتتغيّرش جوّه نفس الاستعلام أصلًا لأنها
   بتقرا من توكن ثابت.

   ١٥ سياسة على ١٢ جدول. استعملنا ALTER POLICY مش DROP+CREATE عشان
   ما يبقاش فيه لحظة واحدة الجدول فيها من غير سياسة.

   اتقاس قبل وبعد: عدد الصفوف الظاهرة لموظف فرع ولأدمن متطابق
   حرفيًا في الاتناشر جدول.
   ============================================================ */

alter policy branch_stores_delete on public.branch_stores
  using ((select jwt_app_role()) = any (array['admin','manager','pharmacist']));

alter policy branch_stores_insert on public.branch_stores
  with check ((select jwt_app_role()) = any (array['admin','manager','pharmacist']));

alter policy branches_admin_write on public.branches
  using ((select jwt_app_role()) = 'admin')
  with check ((select jwt_app_role()) = 'admin');

alter policy dispatch_settings_authed on public.dispatch_settings
  using ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())))
  with check ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())));

alter policy driver_attendance_authed on public.driver_attendance
  using ((select jwt_all_branches()) or exists (
           select 1 from drivers d
            where d.id = driver_attendance.driver_id
              and d.branch_id = (select jwt_branch_id())))
  with check (true);

alter policy drivers_authed on public.drivers
  using ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())))
  with check ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())));

alter policy order_logs_authed on public.order_logs
  using ((select jwt_all_branches()) or exists (
           select 1 from orders o
            where o.id = order_logs.order_id
              and o.branch_id = (select jwt_branch_id())))
  with check (true);

alter policy order_store_override_delete on public.order_store_override
  using ((select jwt_app_role()) = any (array['admin','manager','pharmacist']));

alter policy order_store_override_insert on public.order_store_override
  with check ((select jwt_app_role()) = any (array['admin','manager','pharmacist']));

alter policy order_store_override_update on public.order_store_override
  using ((select jwt_app_role()) = any (array['admin','manager','pharmacist']))
  with check ((select jwt_app_role()) = any (array['admin','manager','pharmacist']));

alter policy orders_authed on public.orders
  using ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())))
  with check ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())));

alter policy org_settings_admin_write on public.org_settings
  using ((select jwt_app_role()) = 'admin')
  with check ((select jwt_app_role()) = 'admin');

alter policy trip_logs_authed on public.trip_logs
  using ((select jwt_all_branches()) or exists (
           select 1 from trips tr
            where tr.id = trip_logs.trip_id
              and tr.branch_id = (select jwt_branch_id())))
  with check (true);

alter policy trip_orders_authed on public.trip_orders
  using ((select jwt_all_branches()) or exists (
           select 1 from trips tr
            where tr.id = trip_orders.trip_id
              and tr.branch_id = (select jwt_branch_id())))
  with check (true);

alter policy trips_authed on public.trips
  using ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())))
  with check ((select jwt_all_branches()) or (branch_id = (select jwt_branch_id())));
