/* ============================================================
   تحديث طلبيات الشراء: حارس تغيير زي بتاع المخزون
   ------------------------------------------------------------
   refresh_purchase_orders بتفضّي purchase_orders_flat وتبنيه من الأول
   **كل ١٠ دقايق مهما كان** — حتى لو مفيش أي جديد.

   الدليل من سجل الكرون (٣ أيام، ٤٣٢ دورة لكل مهمة):
     refresh_stock_flat     : ٢١٤ دورة من ٤٣٢ خلصت في أقل من نص ثانية
                              (الحارس بتاعها بيتخطّى لما المخزون مايتغيّرش)
     refresh_purchase_orders: **صفر** دورة سريعة، أقل زمن ٣.٩٩ ثانية

   يعني نص الدورات تقريبًا بتبني نفس البيانات من غير سبب.

   ⚠️ الجدولة ما اتغيّرتش — فاضلة كل ١٠ دقايق. اللي اتغيّر إن الدورة
   اللي مالهاش جديد بترجع فورًا. أي تغيير حقيقي بيوصل في نفس الـ١٠
   دقايق زي الأول بالظبط.

   البصمة بتغطّي كل مصادر get_purchase_orders: نسخة المخزون
   (stock_flat_meta.src_max) + معدلات الاستهلاك + إعدادات حساب الفروع
   (آخر تعديل وعددها، عشان الحذف يتمسك كمان) + أرخص سعر شراء.

   ⚠️ وعشان ما نعتمدش على البصمة وحدها في حاجة حسّاسة: الشاشات
   (طلبيات الأدوية / إعدادات المؤسسة) بتنادي الدالة بـp_force=true
   بعد أي تعديل إعدادات — فالنتيجة بتتحدّث على طول حتى لو التعديل
   في جدول مش داخل البصمة.

   القياس بعد التطبيق:
     بناء:            4,507 م.ث  → ٤٤٢١ صف
     تخطّي (مفيش جديد):    5 م.ث  → نفس الـ٤٤٢١ صف
     إجبار من الشاشة: 3,903 م.ث  → بناء كامل
   ============================================================ */
create table if not exists public.purchase_orders_flat_meta (
  id           integer primary key,
  src_fp       text,
  refreshed_at timestamptz,
  constraint purchase_orders_flat_meta_single check (id = 1)
);
insert into public.purchase_orders_flat_meta (id) values (1) on conflict (id) do nothing;
revoke all on table public.purchase_orders_flat_meta from public, anon, authenticated;

drop function if exists public.refresh_purchase_orders();

create or replace function public.refresh_purchase_orders(p_force boolean default false)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n int; v_cols text; v_fp text; v_prev text;
begin
  if coalesce(current_setting('request.jwt.claims', true),'') <> '' then
    perform public.require_app_role(array['admin','manager','pharmacist']);
  end if;

  /* بصمة المصادر: لو ماتغيّرتش يبقى الناتج هيطلع نفسه بالحرف */
  select coalesce((select m.src_max::text from public.stock_flat_meta m where m.id = 1), '-')
      || '|' || coalesce((select max(c.refreshed_at)::text from public.consumption_flat c), '-')
      || '|' || coalesce((select max(b.updated_at)::text from public.branch_calc_settings b), '-')
      || '|' || (select count(*)::text from public.branch_calc_settings)
      || '|' || coalesce((select max(p.updated_at)::text from public.best_purchase_by_code p), '-')
    into v_fp;

  select f.src_fp into v_prev from public.purchase_orders_flat_meta f where f.id = 1;

  if not coalesce(p_force, false) and v_prev is not null and v_fp = v_prev then
    return (select count(*)::int from public.purchase_orders_flat);
  end if;

  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'purchase_orders_flat' and column_name <> 'id';

  truncate purchase_orders_flat;
  execute 'insert into purchase_orders_flat (' || v_cols || ')'
       || ' select ' || v_cols || ' from public.get_purchase_orders()';
  get diagnostics n = row_count;

  update purchase_orders_flat p
     set best_pur_store = bpc.price_store
    from best_purchase_by_code bpc
   where bpc.itm_code = p.itm_code;

  update public.purchase_orders_flat_meta
     set src_fp = v_fp, refreshed_at = now()
   where id = 1;

  return n;
end
$function$;

revoke all on function public.refresh_purchase_orders(boolean) from public, anon;
grant execute on function public.refresh_purchase_orders(boolean) to authenticated, service_role;
