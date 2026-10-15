/* ═══════════════════════════════════════════════════════════════════
   شهور الصلاحية إعداد من الشاشة + إصلاح بصمة إعادة البناء
   ═══════════════════════════════════════════════════════════════════
   ── 1) الإعداد ───────────────────────────────────────────────────
   كان الترشيح متسمّر على 12 شهر جوه الدالة. المالك شاف إن 12 كتير
   (صنف تاريخه بعد سنة مش «قرب ينتهي»)، فبقى عمود في
   `purchase_settings` يتعدّل من شاشة إعدادات المؤسسة — **افتراضي 6**.

   ── 2) الباگ اللي اتكشف وقت الاختبار ────────────────────────────
   `refresh_purchase_orders` بتحسب «بصمة مصادر»: لو البصمة زي
   المرة اللي فاتت بترجّع العدد القديم من غير إعادة بناء (migrate_132).
   البصمة كانت فيها `branch_calc_settings` بس — **مش فيها**:

     • `purchase_settings`  → غيّرت `expiry_months` من 12 لـ3 والجدول
       مارجعش يتبني؛ ظهرت نفس الـ184 سطر بتواريخ لـ2027-10.
       ونفس الحكاية على `min_immediate` و`reorder_ratio` العامين.
     • `item_expiry`        → المزامنة اليومية كانت تدخل تواريخ جديدة
       والجدول مايحسّش بيها.
     • `current_date`       → الترشيح نفسه نسبي لليوم؛ بعد نص الليل
       لازم يتحسب تاني.

   البصمة بقيت `md5` للصف كله بدل `updated_at` — عشان ماتعتمدش على
   إن الشاشة فاكرة تحدّث العمود.

   ⚠️ أي إعداد جديد يدخل في حساب الطلبيات **لازم** يدخل البصمة، وإلا
      التعديل يبان في الشاشة ومايأثرش في الأرقام.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) الإعداد ──────────────────────────────────────────────────── */
alter table public.purchase_settings
  add column if not exists expiry_months integer not null default 6;

alter table public.purchase_settings
  drop constraint if exists purchase_settings_expiry_months_chk;
alter table public.purchase_settings
  add  constraint purchase_settings_expiry_months_chk
       check (expiry_months between 1 and 36);

comment on column public.purchase_settings.expiry_months is
  'نافذة «قرب انتهاء الصلاحية» بالشهور — الأصناف اللي بتنتهي خلالها بس هي اللي تترشّح للتحويل. من شاشة إعدادات المؤسسة.';

update public.purchase_settings set expiry_months = 6 where id = 1;

/* ── 2) الدالة بتقرا الإعداد ─────────────────────────────────────── */
create or replace function public.expiry_source_for(p_branch text, p_code text)
returns table (branch text, qty numeric, exp_date date)
language sql
stable
as $fn$
  select e.branch, e.qty, e.exp_date
    from public.item_expiry e
    left join public.consumption_flat cf on cf.code = e.itm_code
   where e.itm_code = p_code
     and e.branch <> p_branch
     and e.exp_date < current_date
         + ((select ps.expiry_months from public.purchase_settings ps where ps.id = 1)
            || ' months')::interval
     and e.qty > coalesce(
           case e.branch
             when 'المعمورة'     then cf.av_mamora
             when 'سان ستيفانو'  then cf.av_san
             when 'سيدى بشر'     then cf.av_bishr
             when 'السيوف'       then cf.av_seyouf
           end, 0) * greatest(0.5, (e.exp_date - current_date) / 30.0)
   order by e.exp_date asc, e.qty desc
   limit 1
$fn$;

revoke all on function public.expiry_source_for(text, text) from public, anon;
grant execute on function public.expiry_source_for(text, text) to authenticated, service_role;

/* ── 3) البصمة ───────────────────────────────────────────────────── */
create or replace function public.refresh_purchase_orders(p_force boolean default false)
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
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
      /* إعدادات المشتريات العامة — md5 للصف كله مش updated_at */
      || '|' || coalesce((select md5(ps::text) from public.purchase_settings ps where ps.id = 1), '-')
      /* تواريخ الصلاحية: المزامنة اليومية لازم تحرّك البصمة */
      || '|' || coalesce((select max(e.synced_at)::text from public.item_expiry e), '-')
      || '|' || (select count(*)::text from public.item_expiry)
      /* الترشيح نسبي لليوم */
      || '|' || current_date::text
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
$fn$;

revoke all on function public.refresh_purchase_orders(boolean) from public, anon;
grant execute on function public.refresh_purchase_orders(boolean) to authenticated, service_role;
