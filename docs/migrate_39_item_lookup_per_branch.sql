-- ═══════════════════════════════════════════════════════════════════
-- item_lookup: كل فرع من جدوله — والخريطة من جدول branches
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**: السحابة والسيرفر الذاتي)
--
-- العيب اللي بيتصلح:
--   الدالة كانت بتاخد p_branch و**ترميه**، وبتقرا من stock_mamora دايمًا:
--       select ... from stock_mamora where itm_code = p_code
--   والشاشة بتبعت الفرع بأمانة (sbItemLookup(code, userBranch)).
--   النتيجة: موظف سان ستيفانو أو سيدى بشر بيكتب كود صنف **موجود على
--   الرف عنده** والدالة ترجّع فاضي لأن المعمورة مش عندها الصنف ده.
--   القياس وقت الإصلاح: 1117 كود في سان + 344 في بشر مش في المعمورة،
--   منهم **802 برصيد فعلي**.
--
-- القرار (المالك): كل فرع يجيب بياناته من فرعه بس — مفيش رجوع لفرع تاني.
--   • فرع محدّد  → جدوله هو، صارم
--   • «كل الفروع» (الأدمن، p_branch فاضي) → يدوّر في الكل وياخد أول نتيجة.
--     الدالة بترجّع **اسم الصنف ونوعه بس** — مفيش رصيد ولا سعر، فمفيش
--     لخبطة بيانات ممكن تحصل من ده.
--
-- ⚠️ ليه dynamic SQL مش view:
--   مزامنة المخزون بتعمل rename ثم drop للجدول القديم. أي view بيتسجّل
--   كاعتماد وبيمنع الـdrop ويوقف المزامنة في كل الفروع (حصل 2026-09-24).
--   أجسام الدوال مش بتتسجّل كاعتماد. واسم الجدول بييجي من branches.code
--   لصف موجود وفعّال — يعني قايمة بيضا، مفيش حقن.
-- ═══════════════════════════════════════════════════════════════════

-- ── مساعد: كود الفرع من الاسم أو الكود أو الاسم البديل ───────────
create or replace function public.branch_code_of(p_branch text)
returns text
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select b.code
    from branches b
   where b.is_active
     and (
       replace(b.name, 'ي', 'ى') = replace(btrim(coalesce(p_branch,'')), 'ي', 'ى')
       or b.code = btrim(coalesce(p_branch,''))
       or exists (select 1 from unnest(coalesce(b.aliases,'{}')) a
                   where replace(a,'ي','ى') = replace(btrim(coalesce(p_branch,'')),'ي','ى'))
     )
   limit 1;
$fn$;

revoke all on function public.branch_code_of(text) from public, anon;
grant execute on function public.branch_code_of(text) to authenticated, service_role;


-- ── البحث عن صنف ─────────────────────────────────────────────────
-- القيم الافتراضية اتحافظ عليها زي الدالة القديمة (لو اتشالت، Postgres
-- بيرفض: cannot remove parameter defaults from existing function)
drop function if exists public.item_lookup(text, text);

create function public.item_lookup(p_code text default null, p_branch text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_code text := btrim(coalesce(p_code, ''));
  v_cd   text;
  v_tbl  text;
  out_j  jsonb;
  r      record;
begin
  if v_code = '' then
    return null;
  end if;

  v_cd := public.branch_code_of(p_branch);

  -- فرع محدّد ومعروف → جدوله هو وبس
  if v_cd is not null then
    v_tbl := 'stock_' || v_cd;
    if to_regclass('public.' || quote_ident(v_tbl)) is null then
      return null;                      -- فرع متسجّل بس جدوله لسه ما اتعملش
    end if;
    execute format(
      'select to_jsonb(t) from (
         select itm_name_ar, itm_name_en, itm_code, itm_ismedicine as item_type
           from public.%I
          where btrim(itm_code) = $1 or btrim(itnl_code) = $1
          limit 1) t', v_tbl)
      into out_j using v_code;
    return out_j;
  end if;

  -- «كل الفروع» → أول نتيجة من أي فرع فعّال
  for r in select b.code from branches b where b.is_active order by b.name loop
    v_tbl := 'stock_' || r.code;
    if to_regclass('public.' || quote_ident(v_tbl)) is not null then
      execute format(
        'select to_jsonb(t) from (
           select itm_name_ar, itm_name_en, itm_code, itm_ismedicine as item_type
             from public.%I
            where btrim(itm_code) = $1 or btrim(itnl_code) = $1
            limit 1) t', v_tbl)
        into out_j using v_code;
      if out_j is not null then
        return out_j;
      end if;
    end if;
  end loop;

  return null;
end $fn$;

revoke all on function public.item_lookup(text, text) from public, anon;
grant execute on function public.item_lookup(text, text) to authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- الفرع الجديد: صف في branches بكود يطابق اسم جدوله (stock_<code>)
-- وبس — الدالة دي مش محتاجة أي تعديل بعد كده.
-- ═══════════════════════════════════════════════════════════════════
