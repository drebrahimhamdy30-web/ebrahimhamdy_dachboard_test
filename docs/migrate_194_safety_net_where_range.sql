-- ═══════════════════════════════════════════════════════════════════
--  شبكتا الأمان: شرط فترة لزرار «سحب فترة»
-- ═══════════════════════════════════════════════════════════════════
--  🛑 اللغم: المحرّك في وضع «سحب فترة» بيدوّر على `where_range` وبيضيفه
--  **لو موجود** — ومفيش «وإلا». المهمتان دول مالهومش `where_range`،
--  فالاستعلام كان هيتنفّذ **بلا أي شرط خالص** ويجيب الجدول كله:
--  1.47 مليون فاتورة (تعاقد وغير تعاقد) تدخل `contract_invoices`،
--  لأن `apply_saved_contracts` كمان مافيهاش فلتر تعاقد — الفلتر عايش
--  في شرط الـSQL بس. جدول فيه 3,500 صف كان هيبقى 1.47 مليون.
--  و`ON CONFLICT DO NOTHING` مش بيحمي: هو بيمنع الدهس مش الإدخال.
--
--  الحارس الأساسي اتحط في المحرّك نفسه (بيرفض السحب لأي خطوة تزايدية
--  بلا `where_range`) — وده بيحمي كل المهام. والترحيل ده بيخلّي الزرار
--  **شغّال وآمن** للمهمتين دول بدل ما يفضل مرفوض.
--
--  ملاحظة على التاريخ: المهام القديمة بتستخدم `< '{to}'`، وده بيسقّط
--  **آخر يوم** بصمت لأن الشاشة بتبعت التاريخ اللي المستخدم اختاره زي
--  ما هو. هنا بنستخدم `< DATEADD(day,1,'{to}')` فاليوم الأخير داخل.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare
  v_sc text := '(h.sth_contract=1 AND h.sec_insert_date >= ''{from}'' AND h.sec_insert_date < DATEADD(day,1,''{to}''))';
  v_ss text := '(h.sth_flag=''C'' AND h.sec_insert_date >= ''{from}'' AND h.sec_insert_date < DATEADD(day,1,''{to}''))';
  v_n  int;
begin
  -- فواتير التعاقد المحفوظة
  update public.sync_jobs
     set steps = jsonb_set(steps, '{0,where_range}', to_jsonb(v_sc), true),
         updated_at = now()
   where id = 'saved_contracts'
     and jsonb_array_length(steps) = 1
     and not (steps -> 0 ? 'where_range');
  get diagnostics v_n = row_count;
  raise notice 'saved_contracts: % صف', v_n;

  -- المبيعات المحفوظة
  update public.sync_jobs
     set steps = jsonb_set(steps, '{0,where_range}', to_jsonb(v_ss), true),
         updated_at = now()
   where id = 'saved_sales'
     and jsonb_array_length(steps) = 1
     and not (steps -> 0 ? 'where_range');
  get diagnostics v_n = row_count;
  raise notice 'saved_sales: % صف', v_n;
end $$;

-- حارس: أي خطوة تزايدية لسه بلا شرط فترة في المهمتين = وقّف
do $$
declare v_bad text;
begin
  select string_agg(j.id, ', ')
    into v_bad
    from public.sync_jobs j, lateral jsonb_array_elements(j.steps) s
   where j.id in ('saved_contracts','saved_sales')
     and (s ? 'where_window' or s ? 'where_new')
     and not (s ? 'where_range');
  if v_bad is not null then
    raise exception 'لسه فيه خطوة تزايدية بلا where_range: %', v_bad;
  end if;
end $$;
