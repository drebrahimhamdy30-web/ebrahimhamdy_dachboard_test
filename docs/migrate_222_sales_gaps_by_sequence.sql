/* ════════════════════════════════════════════════════════════════
   كاشف فجوات المبيعات: يبص على تسلسل الفواتير بدل حدود الأيام
   (2026-11-19)
   ----------------------------------------------------------------
   الكاشف القديم (migrate_178) كان بيقارن **آخر فاتورة في اليوم**
   بـ**أول فاتورة في اليوم اللي بعده** وبس. يعني أي حفرة بتبدأ
   وتخلص جوّه نفس اليوم **غير مرئية له تمامًا** مهما كانت كبيرة.

   ── الحادثة اللي كشفته (سيدي بشر، 16–17/11) ────────────────────
   النت فصل، فضاعت **295 فاتورة**. الشريط قال **94** — لأن الباقي
   (188 + 13) كانوا كلهم جوّه يوم 16/11 الواحد.

   وأسوأ من كده: لما رجعت فاتورة واحدة (39379، الساعة 1:06ص يوم 17)
   بقت هي «أول فاتورة في اليوم»، فالرقم **نزل من 94 لـ34**. يعني
   الشريط كان بيطمّن المالك والمشكلة مكانها. ولو الانقطاع كله حصل
   جوّه يوم واحد، **ما كانش هيظهر من الأساس**.

   ── الحد 5 مش رقم مخترع ────────────────────────────────────────
   توزيع أحجام الكتل على 60 يوم × 4 مخازن:
       حجم 1 → 2,028 مرة    حجم 2 → 81    حجم 3 → 10
       (فراغ تام)
       حجم 13 → مرة واحدة   حجم 188 → مرة واحدة
   الإلغاء الروتيني **عمره ما تعدّى 3**، والفقد الحقيقي بدأ من 13.
   فأي حد بين 4 و12 بيفصل بينهم؛ اخترنا **5**.
   بالحد ده: بشر 201 ناقصة، وباقي المخازن **صفر** — من غير إنذار
   كاذب (الصيدلية كان عندها 7 كتل حجم 3 = 21، وكانت هتوقع إنذار
   كاذب لو عددناها).

   ── p_threshold ────────────────────────────────────────────────
   `get_sync_health` بتنادي `get_sales_gaps(21, 20)` بأرقام محفورة،
   والـ20 دي كانت حد «الفجوة الواحدة». بالمنطق الجديد لو سيبناها
   تحكم، كتلة 13 فاتورة ضايعة كانت هتتبلع في صمت. فالبارامتر بقى
   **بيتسجّل في الناتج للتوافق ومابيحكمش** — الحَكَم هو حجم الكتلة
   (≥5). كده ماحتاجناش نلمس `get_sync_health` خالص.

   ── شكل الناتج ─────────────────────────────────────────────────
   `gaps`   = صف **لكل مخزن** بالمجموع **الحقيقي** (ده اللي الشريط
              بيقراه في session.js: store/missing/after_day/before_day)
   `blocks` = تفصيل كل كتلة لوحدها، للمراجعة.

   مافيش جداول جديدة. التوقيع زي ما هو. يتطبّق على السحابة **و**
   السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.get_sales_gaps(
  p_days      int default 60,
  p_threshold int default 20   -- متسجّل في الناتج للتوافق؛ مابيحكمش (شوف فوق)
) returns jsonb
language sql stable security definer set search_path = public
as $fn$
  with lim as (
    select greatest(coalesce(p_days, 60), 3) as days,
           5 as min_block            -- الحد المبني على توزيع البيانات
  ),
  b as (
    /* فاتورة واحدة لكل رقم: الجدول أسطر بنود مش فواتير */
    select s.store_name, s.bill_no::bigint as bno, min(s.bill_date) as bdate
      from sales_items s, lim
     where (s.bill_date at time zone 'Africa/Cairo')::date
           between current_date - lim.days and current_date - 2
       and s.bill_no ~ '^[0-9]+$'
       and s.store_name is not null
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
               'store',      t.store_name,
               'missing',    t.missing,      -- المجموع الحقيقي لكل المخزن
               'blocks',     t.blocks,
               'biggest',    t.biggest,
               'after_day',  t.after_day,
               'before_day', t.before_day)
             order by t.missing desc)
        from tot t), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'store',      k.store_name,
               'missing',    k.missing,
               'last_bill',  k.last_bill,
               'next_bill',  k.next_bill,
               'after_day',  k.after_day,
               'before_day', k.before_day)
             order by k.missing desc)
        from blk k), '[]'::jsonb)
  )
$fn$;

revoke all on function public.get_sales_gaps(int, int) from public, anon;
grant execute on function public.get_sales_gaps(int, int) to authenticated;

notify pgrst, 'reload schema';
