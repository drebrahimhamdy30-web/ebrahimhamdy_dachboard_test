-- ═══════════════════════════════════════════════════════════════════
--  بوابة الحالة التشغيلية: السيرفر مرآة، فالحالة ممكن تكون متجمّدة
-- ═══════════════════════════════════════════════════════════════════
--  المزامنة ممكن «تنجح» والحالة التشغيلية تفضل غلط. السيرفر صورة من
--  لحظة آخر مزامنة: الطلب اللي كان مفتوح بيفضل مفتوح عنده، والرحلة
--  اللي كانت شغّالة بتفضل شغّالة، والطيار اللي كان أونلاين بيفضل.
--
--  اتقاس 2026-10-18 قبل التحويل:
--      السيرفر: ١٠٠ طلب مفتوح · ١٣ رحلة نشطة · ٢٨ طيار أونلاين
--      السحابة:  ٦٧ طلب مفتوح ·  ٢ رحلة نشطة · ١١ طيار أونلاين
--
--  🔴 ولو فكّينا العزل على الحالة دي، auto_dispatch_tick هيبدأ يوزّع
--     طيارين على طلبات اتسلّمت من أيام. ده مش عرض غلط — ده نظام
--     بيشتغل على بيانات ميتة.
--
--  بيطبع سطر واحد: OK أو تفصيل الفرق.
--  cutover.sh بيشغّله بين المزامنة الأخيرة وفك العزل، وبيوقف لو مش OK.
--
--  🔒 قراءة بس.
-- ═══════════════════════════════════════════════════════════════════

\pset format unaligned
\pset tuples_only on

with srv as (
  select (select count(*) from orders  where status not in ('completed','cancelled')) as opn,
         (select count(*) from trips   where status = 'active')                       as trp,
         (select count(*) from drivers where is_online)                               as onl
), cld as (
  select * from dblink('cloud', $q$
    select (select count(*) from orders  where status not in ('completed','cancelled')),
           (select count(*) from trips   where status = 'active'),
           (select count(*) from drivers where is_online)
  $q$) as t(opn bigint, trp bigint, onl bigint)
)
select case
  when s.opn = c.opn and s.trp = c.trp and s.onl = c.onl then 'OK'
  else 'MISMATCH  مفتوحة ' || s.opn || '/' || c.opn
       || ' · رحلات ' || s.trp || '/' || c.trp
       || ' · أونلاين ' || s.onl || '/' || c.onl
       || '   (سيرفر/سحابة)'
end
from srv s, cld c;
