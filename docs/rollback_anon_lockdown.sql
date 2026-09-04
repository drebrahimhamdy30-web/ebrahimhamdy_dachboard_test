-- ═══════════════════════════════════════════════════════════════════
-- تراجع شامل عن إغلاق anon (2026-09-04)
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ ده بيرجّع الثغرة بالكامل: أي حد بالمفتاح العام (الظاهر في كود كل
--    صفحة) هيقدر يقرا ويكتب ويمسح في كل الجداول تاني.
--    استعمله للطوارئ لو شاشة وقعت، وبعدين دوّر على السبب واقفل تاني.
--
-- السبب الأغلب لو شاشة وقعت: صفحة لسه بتبعت مفتاح anon بدل توكن
-- المستخدم. الحل الصح إنها تتحوّل لـ sbH() / Session.client()، مش ده.
--
-- بديل أضيق (مستحسن): ارجع جدول واحد بس بدل الكل —
--     grant select, insert, update, delete on public.<الجدول> to anon;
--     alter policy <السياسة> on public.<الجدول> to anon, authenticated;

-- 1) صلاحيات الجداول
do $$
declare t record;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
  loop
    execute format('grant select, insert, update, delete on public.%I to anon', t.relname);
  end loop;
end $$;

-- 2) السياسات ترجع تشمل anon
do $$
declare p record;
begin
  for p in
    select tablename, policyname from pg_policies
    where schemaname = 'public' and 'authenticated' = any(roles::text[])
      and not ('anon' = any(roles::text[]) or 'public' = any(roles::text[]))
  loop
    execute format('alter policy %I on public.%I to anon, authenticated', p.policyname, p.tablename);
  end loop;
end $$;

-- 3) الدوال (EXECUTE كانت ممنوحة لـPUBLIC أصلًا)
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in ('sales_summary','sales_overview','sales_by_day','sales_by_hour',
                        'sales_by_employee','sales_top_items','sales_detail','sales_active_days',
                        'sales_discount_stats','sales_discount_bills','sales_price_review',
                        'lookup_customer_name','get_customer_names',
                        'get_closure_machine_recon','get_closure_machine_txns',
                        'add_recon_txn','move_recon_txn','delete_current_wallet_transfer')
  loop
    execute format('grant execute on function %s to anon', f.sig);
  end loop;
end $$;

-- 4) الفيوهات اللي بتتخطى RLS (security_invoker=false)
grant select on public.v_supplier_movements to anon;
grant select on public.v_store_item_prices  to anon;
