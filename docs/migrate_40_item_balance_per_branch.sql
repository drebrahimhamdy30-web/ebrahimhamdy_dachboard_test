-- ═══════════════════════════════════════════════════════════════════
-- item_balance: الفرع من جدول branches بدل أسماء مكتوبة بالحرف
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**: السحابة والسيرفر الذاتي)
--
-- العيب:
--   القديم كان بيقارن نص حرفي:
--       where ... and p_branch = 'المعمورة'
--       union all ... and p_branch = 'سان ستيفانو'
--       union all ... and p_branch in ('سيدى بشر','سيدي بشر')
--   فأي اسم بديل ('الصيدلية' / 'سان' / 'ابراهيم حمدي 2') أو كود ('mamora')
--   كان بيرجّع **0** — واللي مش فارق عن «رصيده صفر فعلاً». عطل صامت.
--
--   القياس وقت الإصلاح: الكود 2577 رصيده 67 في المعمورة بالاسم الرسمي،
--   و0 بـ«الصيدلية» أو بالكود mamora.
--
--   مفيش عطل نشط دلوقتي (stock_limit.branch كله أسماء رسمية) — بس
--   الشاشة بتبعت item?.branch || userBranch، وكفاية مصدر واحد يبعت اسم
--   بديل عشان الرصيد يبان صفر من غير أي علامة.
--
-- وكمان: القديم بيطابق itm_code بس، و item_lookup بتطابق itnl_code كمان.
-- وحّدناهم عشان نفس الكود يلاقي نفس الصنف في الدالتين.
--
-- ⚠️ dynamic SQL مش view: المزامنة بتعمل rename ثم drop للجدول القديم،
--    وأي view بيتسجّل كاعتماد ويمنع الـdrop ويوقف المزامنة في كل الفروع
--    (حصل 2026-09-24). أجسام الدوال مش بتتسجّل كاعتماد.
--
-- بيعتمد على branch_code_of() من migrate_39.
-- ═══════════════════════════════════════════════════════════════════

-- القيم الافتراضية اتحافظ عليها (Postgres بيرفض شيلها من دالة موجودة)
drop function if exists public.item_balance(text, text);

create function public.item_balance(p_code text default null, p_branch text default null)
returns numeric
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_code text := btrim(coalesce(p_code, ''));
  v_cd   text;
  v_tbl  text;
  v_sum  numeric;
begin
  if v_code = '' then
    return 0;
  end if;

  v_cd := public.branch_code_of(p_branch);
  if v_cd is null then
    return 0;                       -- فرع مش معروف: نفس سلوك القديم
  end if;

  v_tbl := 'stock_' || v_cd;
  if to_regclass('public.' || quote_ident(v_tbl)) is null then
    return 0;                       -- فرع متسجّل بس جدوله لسه ما اتعملش
  end if;

  execute format(
    'select coalesce(sum(case when sto_qty_big ~ ''^-?[0-9]+(\.[0-9]+)?$''
                              then sto_qty_big::numeric else 0 end), 0)
       from public.%I
      where btrim(itm_code) = $1 or btrim(itnl_code) = $1', v_tbl)
    into v_sum using v_code;

  return coalesce(v_sum, 0);
end $fn$;

revoke all on function public.item_balance(text, text) from public, anon;
grant execute on function public.item_balance(text, text) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- المقارنة قبل/بعد (السحابة 2026-09-24):
--   الأسماء الرسمية      0 · 67 · 0   →  نفسها بالحرف
--   «الصيدلية»           0            →  67
--   mamora               0            →  67
--   «سان»                0            →  29
--   «سيدي/سيدى بشر»      —            →  26 · 26
--   فرع وهمي             0            →  0
-- ═══════════════════════════════════════════════════════════════════
