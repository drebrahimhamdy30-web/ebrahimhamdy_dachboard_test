-- ═══════════════════════════════════════════════════════════════════
-- الجرد: فئة جديدة «شامبو»
-- ═══════════════════════════════════════════════════════════════════
-- بعد إصلاح المطابقة (migrate_74) الشامبو كان بيقع في «أصناف أخرى» —
-- 355 صنف في المعمورة لوحدها. بقى ليه فئة مستقلة.
--
-- ⚠️ ليه **أول** فئة في الترتيب؟ لأن الفئة الأولى اللي تطابق هي اللي
--    بتتاخد. فيه أسماء شامبو جوّاها كلمات فئات تانية:
--      «PENDULINE SHAMPOO CRADLE CAP»  → كلمة cap كاملة (كانت هتوديه أقراص)
--      «NUTRIVAM 30CAP SHAMPOO OFFER»  → 30cap
--    فلما شامبو تيجي الأول بتمسكهم صح.
--
-- ⚠️ وكلمة «شامبو» هنا **كلمة كاملة** مش «يحتوي على» عن قصد: فيه صنف
--    اسمه «شامبورال كريم 50جم» (كريم مش شامبو) — الكلمة الكاملة بتسيبه
--    لفئة الكريمات صح.
--
-- «shampo» من غير o تانية مقصودة: 8 أصناف مكتوبة كده في الكتالوج.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

-- شامبو الأول، والباقي بيتزحزح واحد
insert into jard_settings (category, keywords_ar, keywords_en, cycle_days, sort_order)
values ('شامبو', array['شامبو','شامبوهات'], array['shampoo','shampoos','shampo'], 7, 0)
on conflict do nothing;

update jard_settings set keywords_ar = array['شامبو','شامبوهات'],
                         keywords_en = array['shampoo','shampoos','shampo'],
                         sort_order  = 0
 where category = 'شامبو';

update jard_settings set sort_order = 1 where category = 'أقراص';
update jard_settings set sort_order = 2 where category = 'أشربة';
update jard_settings set sort_order = 3 where category = 'حقن';
update jard_settings set sort_order = 4 where category = 'لبوس';
update jard_settings set sort_order = 5 where category = 'كريمات';

COMMIT;
