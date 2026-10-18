-- ═══════════════════════════════════════════════════════════════════
--  إعادة بناء جسر السحابة (cloudsrc) — قبل أي مزامنة كاملة
-- ═══════════════════════════════════════════════════════════════════
--  المشكلة: جداول cloudsrc **لقطة** من وقت إنشائها. عمود جديد يتضاف
--  على السحابة، اللقطة مابتعرفهوش، فالمزامنة بتجيب الصفوف من غيره
--  وتكتب فوق المحلي — والعمود **يترجع فاضي**.
--
--  ودي أوحش من ضياع صف: الصف موجود، القيمة جوّاه هي اللي اتمسحت.
--  فالتلف بيبان عشوائي — نفس الجدول، بعض القيم موجودة وبعضها فاضي،
--  ومفيش أي خطأ في أي مكان.
--
--  حصلت قبل كده واتسجّلت كدرس. وحصلت تاني 2026-09-25 في
--  monthly_sales (عمود seyouf). يعني الدرس مكتوب ومفيش حاجة بتنفّذه:
--  المزامنة بتكتشف وتحذّر، وبعدين تكمّل وتكتب الناقص برضه.
--
--  الحل: قبل أي مزامنة كاملة، الجسر يتبني من الأول. عملية رخيصة
--  (تعريفات بس، مفيش نقل بيانات) وبتشيل الفئة دي كلها.
--
--  آمن يتعاد تشغيله. ومابيلمسش أي بيانات.
--
--  التشغيل:
--    docker exec -i $(docker compose ps -q db) psql -U supabase_admin \
--      -d postgres < /root/phalix-repo/docs/reimport_cloudsrc.sql
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

do $$
declare
  names text[];
  n_before int;
  n_after  int;
begin
  -- 🔴 النسخة الأولى كانت بترجّع **نفس مجموعة الجداول الموجودة** بالظبط،
  --    فالجدول الجديد على السحابة عمره ما يدخل الجسر — والمزامنة
  --    مش شايفة له نظير فبتسيبه **فاضي**.
  --    اتكشف 2026-10-18: purchase_invoices و purchase_invoice_items و
  --    purchase_vendors موجودين على السيرفر وفاضيين تمامًا (0 صف)،
  --    والسحابة فيها 20802 و 201438 و 768. والشاشة بتفتح وتقول
  --    «مفيش بيانات» — مش رسالة خطأ، فمحدش بيشك.
  --    يعني عملت أداة للمشكلة دي بالظبط وحافظت على العيب جوّاها.
  -- الحل: نستورد **كل** جداول public من السحابة، مش اللي كان موجود.

  select array_agg(c.relname order by c.relname), count(*)
    into names, n_before
  from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'cloudsrc' and c.relkind = 'f';

  n_before := coalesce(n_before, 0);
  if n_before = 0 then
    raise notice 'الجسر فاضي — أول بناء.';
  else
    raise notice 'الجسر فيه % جدول دلوقتي.', n_before;
  end if;

  -- drop + import في معاملة واحدة: لو الاستيراد وقع، القديم يرجع كامل
  begin
    execute 'drop schema if exists cloudsrc cascade';
    execute 'create schema cloudsrc';
    execute 'import foreign schema public from server cloud into cloudsrc';
  exception when others then
    -- لو الاستيراد الكامل فشل (نوع عمود مش مدعوم مثلًا)، نرجع للمجموعة
    -- القديمة بدل ما نسيب الجسر مكسور — بس نقول بصوت عالي.
    raise notice '⚠️ الاستيراد الكامل فشل: %', left(sqlerrm, 120);
    if n_before = 0 then raise; end if;
    execute 'drop schema if exists cloudsrc cascade';
    execute 'create schema cloudsrc';
    execute format('import foreign schema public limit to (%s) from server cloud into cloudsrc',
                   (select string_agg(quote_ident(x), ', ') from unnest(names) x));
    raise notice '⚠️ رجعنا للمجموعة القديمة (% جدول) — الجداول الجديدة لسه مش في الجسر.', n_before;
  end;

  select count(*) into n_after
  from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'cloudsrc' and c.relkind = 'f';

  -- أرضية تعقّل: المفروض يزيد أو يفضل زي ما هو، مايقلّش
  if n_after < n_before then
    raise exception 'الجسر رجع % جدول بعد ما كان % — بترجع المعاملة.', n_after, n_before;
  end if;
  if n_after < 50 then
    raise exception 'الجسر فيه % جدول بس — رقم غير معقول، بترجع المعاملة.', n_after;
  end if;

  raise notice '✓ الجسر اتبنى من الأول — % جدول (كان %، الفرق %).',
    n_after, n_before, n_after - n_before;
end $$;

select c.relname as "الجدول", count(a.attname) as "الأعمدة"
from pg_class c
join pg_namespace ns on ns.oid = c.relnamespace
left join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
where ns.nspname = 'cloudsrc' and c.relkind = 'f'
group by 1 order by 1;
