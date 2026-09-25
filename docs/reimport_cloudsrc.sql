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
  n int;
begin
  -- الأسماء الموجودة دلوقتي — بنرجّع نفس المجموعة بالظبط
  select array_agg(c.relname order by c.relname) into names
  from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'cloudsrc' and c.relkind = 'f';

  n := coalesce(array_length(names, 1), 0);
  if n = 0 then
    raise exception 'مفيش جداول أجنبية في cloudsrc — حاجة غلط، مش هلمس حاجة.';
  end if;
  raise notice 'هعيد بناء % جدول في الجسر.', n;

  -- drop + import في معاملة واحدة: لو الاستيراد وقع، القديم يرجع
  execute format('drop schema cloudsrc cascade');
  execute 'create schema cloudsrc';
  execute format(
    'import foreign schema public limit to (%s) from server cloud into cloudsrc',
    (select string_agg(quote_ident(x), ', ') from unnest(names) x));

  -- أرضية تعقّل: لازم نفس العدد يرجع
  if (select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = 'cloudsrc' and c.relkind = 'f') <> n then
    raise exception 'رجع عدد مختلف بعد الاستيراد — بترجع المعاملة.';
  end if;

  raise notice '✓ الجسر اتبنى من الأول — % جدول.', n;
end $$;

select c.relname as "الجدول", count(a.attname) as "الأعمدة"
from pg_class c
join pg_namespace ns on ns.oid = c.relnamespace
left join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
where ns.nspname = 'cloudsrc' and c.relkind = 'f'
group by 1 order by 1;
