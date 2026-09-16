-- صلاحية الصنف في سجل الجرد — شهر وسنة بس (اتطبّق على البرودكشن 2026-09-16)
-- ⚠️ make_date مش to_date: to_date مش immutable فمينفعش في عمود مولّد.
ALTER TABLE public.jard_audit_log ADD COLUMN IF NOT EXISTS exp_ym text;
ALTER TABLE public.jard_audit_log DROP CONSTRAINT IF EXISTS jard_exp_ym_chk;
ALTER TABLE public.jard_audit_log ADD CONSTRAINT jard_exp_ym_chk
  CHECK (exp_ym IS NULL OR exp_ym ~ '^[0-9]{4}-(0[1-9]|1[0-2])$');
ALTER TABLE public.jard_audit_log ADD COLUMN IF NOT EXISTS exp_date date
  GENERATED ALWAYS AS (
    CASE WHEN exp_ym ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
         THEN make_date(substr(exp_ym,1,4)::int, substr(exp_ym,6,2)::int, 1) END
  ) STORED;
CREATE INDEX IF NOT EXISTS ix_jard_exp_date ON public.jard_audit_log(exp_date) WHERE exp_date IS NOT NULL;
