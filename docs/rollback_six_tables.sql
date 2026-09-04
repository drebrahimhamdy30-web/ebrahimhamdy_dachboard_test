-- ═══════════════════════════════════════════════════════════════════
-- تراجع فوري عن إغلاق الجداول المالية الستة (المرحلة 3)
-- ═══════════════════════════════════════════════════════════════════
-- شغّله كامل لو أي شاشة وقعت بعد الإغلاق. بيرجّع الوضع بالظبط زي ما كان
-- قبل 2026-09-04: anon يقرا ويكتب في الستة.
-- ⚠️ ده بيرجّع الثغرة — استعمله للطوارئ وبس، وبعدين دوّر على السبب.

grant select, insert, update, delete on public.contracts            to anon;
grant select, insert, update, delete on public.sales_items          to anon;
grant select, insert, update, delete on public.erp_expenses         to anon;
grant select, insert, update         on public.pos_shifts           to anon;
grant select, insert, update, delete on public.pos_wallet_transfers to anon;
grant select, update                 on public.wallet               to anon;

drop policy if exists contracts_anon_all             on public.contracts;
drop policy if exists sales_items_all                on public.sales_items;
drop policy if exists erp_expenses_anon_all          on public.erp_expenses;
drop policy if exists allow_all                      on public.pos_shifts;
drop policy if exists pos_wallet_transfers_all       on public.pos_wallet_transfers;
drop policy if exists "Allow public read on wallet"   on public.wallet;
drop policy if exists "Allow public update on wallet" on public.wallet;

create policy contracts_anon_all       on public.contracts            for all to anon, authenticated using (true) with check (true);
create policy sales_items_all          on public.sales_items          for all to anon, authenticated using (true) with check (true);
create policy erp_expenses_anon_all    on public.erp_expenses         for all to anon, authenticated using (true) with check (true);
create policy allow_all                on public.pos_shifts           for all to public               using (true) with check (true);
create policy pos_wallet_transfers_all on public.pos_wallet_transfers for all to anon, authenticated using (true) with check (true);
create policy "Allow public read on wallet"   on public.wallet for select to public using (true);
create policy "Allow public update on wallet" on public.wallet for update to public using (true) with check (true);

-- ═══════════════════════════════════════════════════════════════════
-- تراجع عن إغلاق الـ15 دالة SECURITY DEFINER (2026-09-04)
-- ═══════════════════════════════════════════════════════════════════
-- الدوال دي بتتخطى RLS، فكانت لسه بتخلّي أي حد بالمفتاح العام يقرا
-- إجمالي المبيعات والخصومات وأسماء الموظفين والعملاء رغم إن الجداول
-- اتقفلت. اتشالت EXECUTE من PUBLIC (مش من anon — anon بيورث من PUBLIC
-- فالسحب منه لوحده مالوش أثر).
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public'
      and p.proname in ('sales_summary','sales_overview','sales_by_day','sales_by_hour',
                        'sales_by_employee','sales_top_items','sales_detail','sales_active_days',
                        'sales_discount_stats','sales_discount_bills','sales_price_review',
                        'lookup_customer_name','get_customer_names',
                        'get_closure_machine_recon','get_closure_machine_txns')
  loop
    execute format('grant execute on function %s to anon', f.sig);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════
-- تراجع عن إغلاق التلات دوال المحروسة + الفيو (2026-09-04)
-- ═══════════════════════════════════════════════════════════════════
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname='public'
      and p.proname in ('add_recon_txn','move_recon_txn','delete_current_wallet_transfer')
  loop
    execute format('grant execute on function %s to anon', f.sig);
  end loop;
end $$;

-- ⚠️ الفيو بيتخطى RLS (security_invoker=false، مالكه postgres) — رجوعه
--    يفتح بيانات erp_expenses تاني حتى والجدول نفسه مقفول.
grant select on public.v_supplier_movements to anon;
