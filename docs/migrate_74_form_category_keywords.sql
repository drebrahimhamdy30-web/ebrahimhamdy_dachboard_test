-- ═══════════════════════════════════════════════════════════════════
-- تصنيف شكل الصنف (أقراص/أشربة/حقن/لبوس/كريمات): كلمات بحدود واضحة
-- ═══════════════════════════════════════════════════════════════════
-- المطابقة في الشاشة كانت «يحتوي على» بشكل أعمى، فطلعت أخطاء زي:
--   • SHAMPOO اتصنّف **حقن** لأن جوّاها amp  (294 صنف في المعمورة لوحدها)
--   • SUPPORT / SUPPLEMENT اتصنّفوا **لبوس** لأن جوّاهم supp (دعامات ومكمّلات)
--   • GELATEXIN / GELET اتصنّفوا **كريمات** لأن جوّاهم gel
--
-- دلوقتي المطابقة في inventory.html بتقسّم الاسم لكلمات وبتحترم حدودها،
-- والنجمة في الكلمة المفتاحية بتتحكّم في السلوك:
--     كلمة     → كلمة كاملة بس        (amp ≠ shampoo)
--     ‎*كلمة    → آخر الكلمة           (‎*gel = emulgel / hydrogel / gengigel)
--     كلمة‎*    → أول الكلمة
--     ‎*كلمة‎*   → في أي مكان (السلوك القديم — مستعمل للعربي عشان السوابق
--                 واللواحق زي «للحقن» و«امبولات»)
--
-- الكلمات دي قابلة للتعديل من شاشة «إعدادات الجرد» زي ما هي.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

update jard_settings set
  keywords_ar = array['*قرص*','*اقراص*','*أقراص*','*كبسول*'],
  keywords_en = array['tab','tabs','tablet','tablets','cap','caps','capsule','capsules']
where category = 'أقراص';

update jard_settings set
  keywords_ar = array['*شراب*','*شرب*','*اشربه*'],
  keywords_en = array['syrp','syrup','syrups','syp']
where category = 'أشربة';

update jard_settings set
  keywords_ar = array['*حقن*','*امبول*','*أمبول*'],
  keywords_en = array['inj','injection','injections','amp','amps','ampoule','ampoules','vial','vials']
where category = 'حقن';

update jard_settings set
  keywords_ar = array['*لبوس*','*قمع*','*اقماع*'],
  keywords_en = array['supp','supps','suppository','suppositories']
where category = 'لبوس';

update jard_settings set
  keywords_ar = array['*كريم*','*مرهم*','جيل','جل'],
  keywords_en = array['cream','creams','oint','ointment','ointments','*gel','gels']
where category = 'كريمات';

COMMIT;
