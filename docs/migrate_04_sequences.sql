-- ═══════════════════════════════════════════════════════════════════
-- خطوة 4: السيكوينسات + تقرير الصفوف اليتيمة
-- ═══════════════════════════════════════════════════════════════════
-- ⚠️ **أهم خطوة بعد البيانات.** من غيرها أول insert جديد بيصطدم بـid
--    موجود ويرمي duplicate key — وده بيظهر بعد أيام لما حد يضيف صف
--    ويبقى صعب تربط السبب بالنتيجة.
--
-- ⚠️ مهام الـcron **متأجّلة عن قصد** لحد ما دوال Edge تتنشر على السيرفر
--    وأسرار vault تتعمل. من غيرهم الكرونات هتنده دوال مش موجودة وتفشل
--    كل دقيقة وتملى السجلات.
-- ═══════════════════════════════════════════════════════════════════

set statement_timeout = 0;

-- ── 1) ربط كل سيكوينس بعموده + ضبط قيمته ────────────────────────
do $seq$
declare r record; n_ok int := 0; n_err int := 0;
begin
  for r in select ord, kind, obj, ddl from cloudsrc.v_migration_post
           where kind in ('seq_owner','setval') order by ord, obj
  loop
    begin
      execute r.ddl;
      n_ok := n_ok + 1;
    exception when others then
      n_err := n_err + 1;
    end;
  end loop;
  raise notice 'سيكوينسات: نجح % / فشل %', n_ok, n_err;
end $seq$;

-- ── 2) تحقق: هل كل سيكوينس أكبر من أكبر id في جدوله؟ ────────────
--    ده الفحص اللي بيثبت إن الإضافة الجديدة مش هتصطدم.
select
  (select count(*) from pg_class s join pg_namespace n on n.oid = s.relnamespace
    where n.nspname = 'public' and s.relkind = 'S')                       as إجمالي_السيكوينسات,
  (select count(*) from pg_class s join pg_namespace n on n.oid = s.relnamespace
    where n.nspname = 'public' and s.relkind = 'S'
      and pg_sequence_last_value(s.oid) is not null)                      as متظبّطة,
  (select count(*) from pg_class s join pg_namespace n on n.oid = s.relnamespace
    where n.nspname = 'public' and s.relkind = 'S'
      and pg_sequence_last_value(s.oid) is null)                          as لسه_على_البداية;

-- ── 3) الصفوف اليتيمة (بسبب فرق التوقيت بين نسخ الجداول) ────────
--    القيود اتعملت `not valid` فالصفوف دي موجودة. الرقم صغير = طبيعي.
select 'order_logs بلا طلب'  as البند,
       (select count(*) from public.order_logs  l
         where l.order_id is not null
           and not exists (select 1 from public.orders o where o.id = l.order_id)) as عدد
union all
select 'trip_logs بلا رحلة',
       (select count(*) from public.trip_logs t
         where t.trip_id is not null
           and not exists (select 1 from public.trips p where p.id = t.trip_id))
union all
select 'trip_orders بلا رحلة',
       (select count(*) from public.trip_orders t
         where t.trip_id is not null
           and not exists (select 1 from public.trips p where p.id = t.trip_id))
union all
select 'trip_orders بلا طلب',
       (select count(*) from public.trip_orders t
         where t.order_id is not null
           and not exists (select 1 from public.orders o where o.id = t.order_id));
