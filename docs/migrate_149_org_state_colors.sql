-- ═══════════════════════════════════════════════════════════════════
-- ألوان الحالة من إعدادات المؤسسة                   (2026-10-17)
--
-- الهدف: التحكم في ألوان النظام كله من مكان واحد.
-- قبل كده كان فيه ~2786 لون مكتوب بالإيد في 59 شاشة، فتغيير هوية
-- العميل كان بيسيب بقع من الألوان القديمة في كل مكان.
--
-- لون **واحد** لكل عائلة، والدرجات (الغامق/الخلفية/الخلفية الفاتحة)
-- بتتشقّ منه في brand.js — عشان ما يبقاش قدام المستخدم ١٥ خانة لون.
--
-- القيم الفاضية مقصودة: التوكن بيفضل على قيمته في tokens.css، يعني
-- مفيش تغيير بصري لحد ما المالك يختار لون بنفسه.
-- ═══════════════════════════════════════════════════════════════════

alter table public.org_settings
  add column if not exists color_ok     text,
  add column if not exists color_danger text,
  add column if not exists color_warn   text,
  add column if not exists color_info   text;

comment on column public.org_settings.color_ok     is 'لون النجاح (hex). الدرجات بتتشق منه في brand.js. فاضي = قيمة tokens.css';
comment on column public.org_settings.color_danger is 'لون الخطر/الرفض (hex)';
comment on column public.org_settings.color_warn   is 'لون التنبيه (hex)';
comment on column public.org_settings.color_info   is 'لون المعلومة (hex)';

notify pgrst, 'reload schema';

select brand_primary, brand_note, color_ok, color_danger, color_warn, color_info
  from public.org_settings where id = 1;
