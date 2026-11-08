/* ═══════════════════════════════════════════════════════════════════
   ثلاثة أعطال في المزامنة كانت بتخلّي الأرقام تكدب بصمت
   ═══════════════════════════════════════════════════════════════════
   اتكشفوا 2026-11-08 وأنا بجهّز لشاشة الموقف اليومي. التلاتة مشتركين
   في صفة واحدة: **مفيش حاجة بتصرخ** — الجداول فيها بيانات، والجولات
   بتقول «تم»، والأرقام غلط أو ناقصة.

   ── (١) `synced_at` بيكدب في ١٥ جدول ─────────────────────────────
   العمود معرّف `DEFAULT now()`، والافتراضي ده بيشتغل عند **الإدراج
   بس**. ومحرّك المزامنة بيبعت أعمدة البيانات من غير `synced_at`،
   فالـupsert بيحدّث الأرقام ويسيب التاريخ زي ما هو — تاريخ أول يوم
   اتدرج فيه الصف.

   النتيجة العملية: `purchase_vendors` كان عليه `2026-10-08` لكل
   الصفوف، فبان إن أرصدة الموردين واقفة شهر. قارنت ١٩٣ مورّد بـeplus
   الحي: **١٩٢ مطابقين بالمليم**. الأرقام كانت حيّة والتاريخ هو
   الواقف — واتخدعت بيه أنا شخصيًا وبلّغت المالك بعطل مش موجود.

   ⚠️ **أي حارس تأخّر بيقرا `synced_at` على الجداول دي بيكدب بنفس
      الطريقة** — ودي الخطورة الحقيقية مش العرض.

   العلاج: `touch_synced_at()` (موجودة أصلًا ومستعملة في
   `eplus_safes`) تتركّب على باقي جداول المزامنة.
   `item_expiry` مستثنى — عنده تريجر خاص (`item_expiry_stamp`)
   بيعمل أكتر من ختم الوقت، وما ينفعش يتبدّل.

   ── (٢) الربحية الشهرية واقفة عند أكتوبر ─────────────────────────
   مهمة `eplus_monthly_pnl` فيها **تواريخ مكتوبة بالأيد**:
   `>= '20260101' AND < '20261101'` في سبع خطوات، و
   `>= '20251210' AND < '20261110'` في خطوة المرتبات.

   يعني المهمة كانت متظبّطة لتاريخ كتابتها، وأول ما دخل نوفمبر بقت
   بتجيب لحد أكتوبر وبس — **وبترجّع «ok»** في كل جولة. الجدول فيه
   بيانات لحد `2026-10` والجولات بعد `2026-11-06` كلها صفر صفوف.
   نوفمبر موجود في eplus (المعمورة لوحدها ٦١٠١ فاتورة) ومستنّي.

   العلاج: الحدود تبقى محسوبة وقت التشغيل — من أول الشهر قبل ١٢ شهر
   لحد أول الشهر الجاي (عشان الشهر الحالي يدخل كامل). وخطوة المرتبات
   بنفس المنطق مزاح ٩ أيام لأن شهر المرتب بيبدأ من ١٠.
   اتجرّبت الصيغة على SQL Server 2000 نفسه قبل الكتابة:
     DATEADD(month, DATEDIFF(month,0,GETDATE())-12, 0) → 2025-11-01
     DATEADD(month, DATEDIFF(month,0,GETDATE())+1,  0) → 2026-12-01

   ⚠️ **أي تاريخ ثابت في مهمة دورية = قنبلة موقوتة بتنفجر بصمت.**

   ── (٣) مهمة الخزائن متقفّلة ──────────────────────────────────────
   `safes` (أرصدة `F_Cash_Store`) آخر بيانات ليها `2026-10-24` لأنها
   `enabled=false`. الكاش رقم أساسي في الموقف المالي.
   يوميًا كفاية — الرصيد لقطة مش حركة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ─── (١) ختم وقت المزامنة على التعديل مش الإدراج بس ─────────────── */

create or replace function public.touch_synced_at()
returns trigger language plpgsql as $$
begin
  new.synced_at := now();
  return new;
end $$;

do $$
declare
  t text;
  /* جداول المزامنة اللي فيها synced_at. item_expiry مستثنى عن قصد:
     تريجره بيكتب سجل التغيّر كمان مش بس الوقت. */
  tables text[] := array[
    'branch_goods', 'branch_goods_items', 'branch_transfers',
    'cashier_transactions', 'contract_backfill_stage',
    'eplus_item_units', 'eplus_monthly_pnl', 'eplus_monthly_salary',
    'eplus_monthly_shortage', 'eplus_price_changes',
    'purchase_invoice_items', 'purchase_invoices', 'purchase_returns',
    'purchase_vendors', 'sales_backfill_stage', 'shift_changes',
    'stock_adjustments'
  ];
begin
  foreach t in array tables loop
    if to_regclass('public.' || quote_ident(t)) is null then
      raise notice 'تخطّي %: الجدول مش موجود', t;
      continue;
    end if;
    if not exists (
      select 1 from information_schema.columns
       where table_schema='public' and table_name=t and column_name='synced_at') then
      raise notice 'تخطّي %: مفيش عمود synced_at', t;
      continue;
    end if;
    execute format('drop trigger if exists trg_%I_synced on public.%I', t, t);
    execute format(
      'create trigger trg_%I_synced before update on public.%I
         for each row execute function public.touch_synced_at()', t, t);
  end loop;
end $$;

/* ─── (٢) حدود الربحية الشهرية تتحسب وقت التشغيل ─────────────────── */

update public.sync_jobs
   set steps = replace(replace(replace(replace(
         steps::text,
         '''20260101''', 'DATEADD(month, DATEDIFF(month,0,GETDATE())-12, 0)'),
         '''20261101''', 'DATEADD(month, DATEDIFF(month,0,GETDATE())+1, 0)'),
         '''20251210''', 'DATEADD(day, 9, DATEADD(month, DATEDIFF(month,0,GETDATE())-12, 0))'),
         '''20261110''', 'DATEADD(day, 9, DATEADD(month, DATEDIFF(month,0,GETDATE())+1, 0))'
       )::jsonb,
       enabled = true,
       interval_minutes = 1440,
       updated_at = now()
 where id = 'eplus_monthly_pnl';

/* حارس: لو فضل أي تاريخ ثابت في المهمة يبقى الاستبدال ما تمّش */
do $$
declare n int;
begin
  select count(*) into n
    from public.sync_jobs
   where id='eplus_monthly_pnl' and steps::text ~ '''20\d{6}''';
  if n > 0 then
    raise exception 'لسه فيه تواريخ ثابتة في eplus_monthly_pnl — الاستبدال ما كملش';
  end if;
end $$;

/* ─── (٣) تشغيل مهمة أرصدة الخزائن ──────────────────────────────── */

update public.sync_jobs
   set enabled = true, interval_minutes = 1440, updated_at = now()
 where id = 'safes';

notify pgrst, 'reload schema';
