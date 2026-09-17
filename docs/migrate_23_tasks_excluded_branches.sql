-- تنظيم المهام: استثناء فرع أو أكتر من مهمة (اتطبّق على البرودكشن 2026-09-17)
-- الفروع المستثناة مابتشوفش المهمة خالص (شاشة المهام + «مهام اليوم» في البار)
-- ومش بتترحّل عليها. فاضي = كل الفروع زي قبل كده. الأسماء = branches.name.
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS excluded_branches text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN public.tasks.excluded_branches IS 'الفروع المستثناة من المهمة (أسماء branches.name) — فاضي = كل الفروع';
NOTIFY pgrst, 'reload schema';
