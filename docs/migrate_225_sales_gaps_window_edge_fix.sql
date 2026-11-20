/* ════════════════════════════════════════════════════════════════
   كاشف فجوات المبيعات: إصلاح إنذار كاذب عند حافة النافذة
   (2026-11-20 — تصحيح لـmigrate_222 اللي اتعمل امبارح)
   ----------------------------------------------------------------
   ⛔ **الكاشف أطلق إنذار كاذب أول يوم**: «الصيدلية — 20 فاتورة يوم
   2026-10-30». الفحص: **19 منهم موجودين فعلًا**، بتاريخ **29/10**
   الساعة 11:23م–11:59م. الناقص الحقيقي **فاتورة واحدة** (ملغية).

   ── السبب ──────────────────────────────────────────────────────
   migrate_222 كان بيعمل حاجتين متعارضتين في نفس الاستعلام:
     • بيفلتر الصفوف **بالتاريخ** (آخر 21 يوم)
     • وبيقيس الفجوة **بالتسلسل الرقمي** على الصفوف المفلترة
   والاتنين مابيتفقوش عند **حدود النافذة**: فاتورة رقمها جوّه النطاق
   وتاريخها برّا النافذة بتختفي من المجموعة، فالتسلسل بيبان فيه
   حفرة وهي مش موجودة. النهارده النافذة بدأت 30/10 بالظبط، فكل
   فواتير آخر ساعة في 29/10 وقعت برّه.

   (وده بيحصل كمان في أي مكان ترتيب التاريخ مايوافقش ترتيب الرقم.)

   ── الإصلاح ────────────────────────────────────────────────────
   التاريخ بقى بيحدّد **نطاق الأرقام** اللي يهمنا وبس، والحضور
   بيتقاس جوّه النطاق ده **بأي تاريخ**. يعني فاتورة موجودة بأي
   تاريخ = حاضرة، والفجوة بقت «رقم مش موجود خالص» مش «رقم برّا
   النافذة».

   ── التحقق ─────────────────────────────────────────────────────
   • الإنذار الكاذب اختفى (الشريط رجع فاضي).
   • والكشف لسه شغّال: محاكاة إخفاء 30 فاتورة من المعمورة اتمسكت
     بالظبط (1512000–1512029).
   • الأداء: 880 → 604 مللي بعد الفهرس الجزئي (migrate_225b).
     النداء في الخلفية فمش بيعطّل فتح الشاشة.

   🔑 **الدرس**: ماينفعش تقيس اكتمال **تسلسل** على مجموعة مفلترة
   **بالتاريخ**. حدّد النطاق بالتاريخ، وقيس الحضور على التسلسل كله.

   التوقيع زي ما هو، ومحدش تاني بينادي الدالة غير get_sync_health.
   يتطبّق على السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.get_sales_gaps(
  p_days      int default 60,
  p_threshold int default 20
) returns jsonb
language sql stable security definer set search_path = public
as $fn$
  with lim as (
    select greatest(coalesce(p_days, 60), 3) as days, 5 as min_block
  ),
  -- ١) التاريخ بيحدّد **نطاق الأرقام** اللي يهمنا، وبس.
  win as (
    select s.store_name, min(s.bill_no::bigint) as lo, max(s.bill_no::bigint) as hi
      from sales_items s, lim
     where (s.bill_date at time zone 'Africa/Cairo')::date
           between current_date - lim.days and current_date - 2
       and s.bill_no ~ '^[0-9]+$'
       and s.store_name is not null
     group by 1
  ),
  -- ٢) الحضور بيتقاس جوّه النطاق ده **بأي تاريخ** — ده الإصلاح.
  b as (
    select s.store_name, s.bill_no::bigint as bno, min(s.bill_date) as bdate
      from sales_items s
      join win w on w.store_name = s.store_name
     where s.bill_no ~ '^[0-9]+$'
       and s.bill_no::bigint between w.lo and w.hi
     group by 1, 2
  ),
  j as (
    select store_name, bno, bdate,
           lead(bno)   over w as nx,
           lead(bdate) over w as nx_date
      from b
    window w as (partition by store_name order by bno)
  ),
  blk as (
    select store_name,
           bno as last_bill, nx as next_bill, (nx - bno - 1) as missing,
           (bdate   at time zone 'Africa/Cairo')::date as after_day,
           (nx_date at time zone 'Africa/Cairo')::date as before_day
      from j, lim
     where nx is not null and (nx - bno - 1) >= lim.min_block
  ),
  tot as (
    select store_name, count(*)::int as blocks, sum(missing)::int as missing,
           max(missing)::int as biggest,
           min(after_day) as after_day, max(before_day) as before_day
      from blk group by 1
  )
  select jsonb_build_object(
    'checked_at', now(),
    'days',       (select days from lim),
    'min_block',  (select min_block from lim),
    'threshold',  greatest(coalesce(p_threshold, 20), 1),
    'gaps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'store', t.store_name, 'missing', t.missing, 'blocks', t.blocks,
               'biggest', t.biggest, 'after_day', t.after_day, 'before_day', t.before_day)
             order by t.missing desc) from tot t), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'store', k.store_name, 'missing', k.missing,
               'last_bill', k.last_bill, 'next_bill', k.next_bill,
               'after_day', k.after_day, 'before_day', k.before_day)
             order by k.missing desc) from blk k), '[]'::jsonb)
  )
$fn$;

revoke all on function public.get_sales_gaps(int, int) from public, anon;
grant execute on function public.get_sales_gaps(int, int) to authenticated;

/* migrate_225b — فهرس يخلّي المقارنة الرقمية تستخدم فهرس بدل مسح كامل */
create index if not exists idx_sales_items_store_billno_num
  on public.sales_items (store_name, ((bill_no)::bigint))
  where bill_no ~ '^[0-9]+$';

analyze public.sales_items;

notify pgrst, 'reload schema';
