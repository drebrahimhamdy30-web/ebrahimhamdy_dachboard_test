-- ═══════════════════════════════════════════════════════════════════
--  migrate_32 — تصحيح أسماء الفهارس + تفعيل المفاتيح الأجنبية
-- ═══════════════════════════════════════════════════════════════════
--
--  ═══ 1) أسماء الفهارس — تصحيح غلطة في migrate_29 ═══
--  في migrate_29 مسحنا الفهرس المكرر على stock_* وقلنا إننا بنسيب
--  اللي زي البرودكشن. الفحص المباشر للسحابة بعد كده طلّع العكس:
--      السحابة: bishr → _idx  ·  mamora → _idx  ·  san → _idx1
--  يعني مسحنا المطابق وسيبنا غير المطابق. الأثر العملي صفر (الفهرسين
--  كانوا نسخة طبق الأصل UNIQUE على نفس العمود، والحماية من التكرار
--  فضلت شغّالة) — بس الاسم بيفرق للحارس وللسكربتات اللي بتنده الاسم.
--  التصحيح إعادة تسمية، مش إعادة بناء (ثانية واحدة مش دقايق).
--
--  ═══ 2) المفاتيح الأجنبية الـ4 — NOT VALID ═══
--  order_logs · trip_logs · trip_orders (×2)
--  اتشالت وقت الترحيل الأصلي لأن الأبناء اتنقلوا قبل الآباء، ورجعت
--  NOT VALID يعني: **بتمنع الصفوف الجديدة الغلط، ومابتفحصش القديم**.
--  البرودكشن عنده نفس القيود متحقَّقة بالكامل.
--
--  بعد المزامنة الكاملة (2026-09-19) الآباء كلهم اتنقلوا، فالمفروض
--  مفيش صفوف يتيمة. السكربت **بيعدّ الأول**:
--    • صفر يتيم  → بيفعّل القيد
--    • فيه يتامى → بيقول العدد ومابيعملش حاجة (قرار حذف بيانات
--                  مش قرار سكربت)
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ── 1) أسماء الفهارس ───────────────────────────────────────────────
do $ix$
declare
  pairs constant text[][] := array[
    ['stock_bishr_staging_itm_code_idx1',  'stock_bishr_staging_itm_code_idx'],
    ['stock_mamora_staging_itm_code_idx1', 'stock_mamora_staging_itm_code_idx'],
    ['stock_san_staging_itm_code_idx',     'stock_san_staging_itm_code_idx1']
  ];
  i int; n int := 0;
begin
  for i in 1 .. array_length(pairs, 1) loop
    if exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
               where ns.nspname = 'public' and c.relname = pairs[i][1] and c.relkind = 'i')
       and not exists (select 1 from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
                       where ns.nspname = 'public' and c.relname = pairs[i][2]) then
      execute format('alter index public.%I rename to %I', pairs[i][1], pairs[i][2]);
      n := n + 1;
      raise notice '  ✓ % → %', pairs[i][1], pairs[i][2];
    end if;
  end loop;
  raise notice '═══ فهارس اتسمّت من جديد: % ═══', n;
end $ix$;

-- ── 2) المفاتيح الأجنبية ───────────────────────────────────────────
do $fk$
declare
  fks constant text[][] := array[
    -- [الجدول, العمود, القيد, جدول الأب, عمود الأب]
    ['order_logs',  'order_id', 'order_logs_order_id_fkey',  'orders', 'id'],
    ['trip_logs',   'trip_id',  'trip_logs_trip_id_fkey',    'trips',  'id'],
    ['trip_orders', 'order_id', 'trip_orders_order_id_fkey', 'orders', 'id'],
    ['trip_orders', 'trip_id',  'trip_orders_trip_id_fkey',  'trips',  'id']
  ];
  i int; v_orphans bigint; n_ok int := 0; n_skip int := 0; n_miss int := 0;
begin
  for i in 1 .. array_length(fks, 1) loop
    -- القيد موجود أصلًا؟
    if not exists (select 1 from pg_constraint con
                   join pg_class c on c.oid = con.conrelid
                   join pg_namespace ns on ns.oid = c.relnamespace
                   where ns.nspname = 'public' and con.conname = fks[i][3]) then
      raise notice '  ⚠️ % مش موجود خالص — محتاج إنشاء مش تفعيل', fks[i][3];
      n_miss := n_miss + 1;
      continue;
    end if;

    -- متحقَّق خلاص؟
    if exists (select 1 from pg_constraint con where con.conname = fks[i][3] and con.convalidated) then
      n_ok := n_ok + 1;
      continue;
    end if;

    -- عدّ الصفوف اليتيمة قبل أي حاجة
    execute format(
      'select count(*) from public.%I ch left join public.%I p on p.%I = ch.%I
        where ch.%I is not null and p.%I is null',
      fks[i][1], fks[i][4], fks[i][5], fks[i][2], fks[i][2], fks[i][5])
      into v_orphans;

    if v_orphans = 0 then
      execute format('alter table public.%I validate constraint %I', fks[i][1], fks[i][3]);
      raise notice '  ✓ % اتفعّل (صفر يتيم)', fks[i][3];
      n_ok := n_ok + 1;
    else
      raise notice '  ⚠️ %: % صف يتيم — القيد سايب NOT VALID (حذف بيانات = قرارك مش قرار سكربت)',
        fks[i][3], v_orphans;
      n_skip := n_skip + 1;
    end if;
  end loop;

  raise notice '═══ متحقَّق: %  ·  موقوف ليتامى: %  ·  ناقص: % ═══', n_ok, n_skip, n_miss;
end $fk$;

-- ── التحقق ─────────────────────────────────────────────────────────
select conname as "القيد",
       case when convalidated then '✓ متحقَّق' else '⚠️ NOT VALID' end as "الحالة"
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and con.contype = 'f' and not con.convalidated
order by 1;
