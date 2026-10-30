/* ════════════════════════════════════════════════════════════════
   حارس اكتمال المبيعات + علامة الصفوف المعوَّضة   (2026-10-30)
   ----------------------------------------------------------------
   **ليه**: يوم ٢٦/١٠/٢٠٢٦ كامل ضاع من مبيعات المعمورة — ٨٣٣ فاتورة
   و١٦٨ ألف جنيه، منهم ٢٥ فاتورة تعاقد. وماحدّش حسّ لمدة ٤ أيام لحد
   ما المالك دوّر على فاتورة بعينها ومالقهاش.

   **السبب الجذري**: وركفلو المبيعات في n8n بيشتغل **مرة واحدة يوميًا
   الساعة 00:01 بنافذة يومين**. اتأكدنا من `created_at`: كل ليلة
   بتدخّل اليوم اللي فات وبتلمس اللي قبله. ليلة ٢٧ وليلة ٢٨ **الاتنين
   ماشتغلوش** (مفيش ولا صف `created_at` في اليومين دول)، ولأن النافذة
   يومين بس فاليوم اللي كان المفروض الجولتين يغطّوه — ٢٦ — ضاع للأبد.
   جولة واحدة بتفشل بتتعالج لوحدها؛ **جولتين ورا بعض = فقد دائم صامت**.

   **وليه التنبيه الموجود ماشفهوش**: `get_sync_health` بيقيس «آخر
   بيانات وصلت» — ويوم ٢٧ وصل عادي، فالثقب اللي في النص مالوش أي أثر
   في مقياس الحداثة. الحداثة ماتكشفش ثقب في النص، لازم مقياس اكتمال.

   **الفكرة**: أرقام الفواتير متسلسلة لكل فرع. فأي فقد بيبان كقفزة في
   التسلسل بين آخر فاتورة في يوم وأول فاتورة في اليوم اللي بعده —
   **من غير ما نسأل eplus أصلًا**. قِسنا التوزيع على ٧٠ يوم × ٤ فروع:
   الطبيعي **٠–٩** (فواتير ملغاة عند حدود اليوم)، والشذوذ الوحيد كان
   ٨٥٨ (الحادثة) و٢٣١ و٢٣٨ (حادثتين أقدم في ابراهيم حمدي ٢ و٣ محدش
   كان واخد باله منهم). فالحد ٢٠ بيفصل نضيف من غير إنذار كاذب.

   ⚠️ بنفحص لحد `current_date - 2` بس: مزامنة الليلة بتدخّل أمبارح،
      والنافذة بتلمسه تاني الليلة اللي بعدها — فأي فحص لآخر يومين
      بيطلّع إنذار كاذب كل صبح.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

/* ── ١) علامة الصفوف اللي اتعوّضت يدويًا من eplus ───────────────
   مش تجميل: الصفوف دي سعر مخزونها معاد بناؤه من تاريخ تغيّرات
   الأسعار مش مقروء لحظة البيع، فشاشة «مراجعة الأسعار» المفروض
   تفرّقها عن الصفوف اللي جات من المزامنة الحقيقية. */
alter table public.sales_items
  add column if not exists backfilled boolean not null default false;

comment on column public.sales_items.backfilled is
  'صف اتعوّض من eplus بعد فشل مزامنة — سعر المخزون فيه معاد بناؤه مش مقروء وقت البيع';

/* ── ٢) ثقوب تسلسل الفواتير ──────────────────────────────────── */
create or replace function public.get_sales_gaps(
  p_days      int default 60,
  p_threshold int default 20
) returns jsonb
language sql stable security definer set search_path = public
as $fn$
  with d as (
    select store_name,
           (bill_date at time zone 'Africa/Cairo')::date as dy,
           min(bill_no::bigint) as min_b,
           max(bill_no::bigint) as max_b,
           count(distinct bill_no) as bills
      from sales_items
     where (bill_date at time zone 'Africa/Cairo')::date
           between current_date - greatest(coalesce(p_days,60),3) and current_date - 2
       and bill_no ~ '^[0-9]+$'
     group by 1,2
  ),
  j as (
    select store_name, dy, max_b, bills,
           lead(dy)    over w as next_dy,
           lead(min_b) over w as next_min,
           lead(min_b) over w - max_b - 1 as jump
      from d
    window w as (partition by store_name order by dy)
  )
  select jsonb_build_object(
    'checked_at', now(),
    'days',       greatest(coalesce(p_days,60),3),
    'threshold',  greatest(coalesce(p_threshold,20),1),
    'gaps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'store',      store_name,
               'after_day',  dy,
               'before_day', next_dy,
               'last_bill',  max_b,
               'next_bill',  next_min,
               'missing',    jump)
             order by jump desc)
        from j
       where next_dy is not null
         and jump >= greatest(coalesce(p_threshold,20),1)), '[]'::jsonb));
$fn$;

revoke all on function public.get_sales_gaps(int, int) from public, anon;
grant execute on function public.get_sales_gaps(int, int) to authenticated;

/* ── ٣) نضمّه لفحص المزامنة بدل نداء تاني ─────────────────────
   جراحيًا: بنزوّد مفتاح 'sales_gaps' على الناتج ومابنلمسش أي منطق
   تاني في الدالة — الشاشات اللي بتقرا branches/feeds ماتتأثرش. */
do $do$
declare src text; new_src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_sync_health';
  if src is null then
    raise notice 'get_sync_health مش موجودة — اتخطّينا الضم';
    return;
  end if;
  if src like '%sales_gaps%' then
    raise notice 'get_sync_health متضمّنة الثقوب قبل كده';
    return;
  end if;
  new_src := replace(src,
    $old$    'feeds',           feeds);$old$,
    $new$    'feeds',           feeds,
    'sales_gaps',      coalesce(public.get_sales_gaps(60, 20) -> 'gaps', '[]'::jsonb));$new$);
  if new_src = src then
    raise exception 'مالقيتش سطر الإرجاع في get_sync_health — راجع الدالة يدويًا';
  end if;
  execute new_src;
end $do$;
