-- ═══════════════════════════════════════════════════════════════════
-- get_stock_summary: الفروع من الجدول، والخريطة بترجع مع الرد
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- ليه: الدالة كانت بتكتب الفروع الأربعة بالإيد في `meta` و`items`.
--   والشاشتين اللي بينادوها (inventory_management · cosmo_order) كانوا
--   بيكتبوا خريطة كود→حرف بالإيد كذلك (`BR_LETTER`).
--
-- القرار: الدالة ترجّع `meta.branches` = [{code, name, letter, sort}]،
--   فالشاشة تبني خريطتها من الرد نفسه. البديل كان إضافة `letter` في
--   branches.js — وده كان معناه تحديث الـcache-bust في **54 ملف**
--   بيحمّلوه، مقابل ملفين بس بينادوا الدالة دي.
--
-- ⚠️ الأداء — ده القيد الحاكم في الدالة دي:
--   بترجّع ~28,700 صنف وعليها شاشتين. وفي سابقة إن شغل «لكل صف» جوّاها
--   خلّى الاستجابة 49 ثانية (راجع stock-summary-supabase).
--   عشان كده **مفيش `to_jsonb(row)` لكل صف هنا**: نص الاستعلام بيتبني
--   مرة واحدة من جدول الفروع وبعدين بيتنفّذ، فالتكلفة زي المكتوب
--   بالإيد بالظبط — الفرق إن الأعمدة جاية من `branches.letter`.
--
-- ⚠️ فرع ليه حرف بس أعمدته مش في stock_flat: بيرجع بأصفار **ظاهرة**
--   مش بيتشال من الرد. عمود أصفار بيسأل عنه حد؛ فرع مختفي محدش
--   بياخد باله منه — ودي بنية الفشل اللي بتضرب النظام ده عادةً.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.get_stock_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_meta  jsonb := '{}'::jsonb;
  v_brs   jsonb := '[]'::jsonb;
  v_items jsonb;
  v_sel   text  := '';
  v_cnt   bigint;
  v_upd   timestamptz;
  v_tbl   text;
  r       record;
begin
  for r in select * from public.branch_letters() loop

    -- ① meta: عدد الأصناف وآخر تحديث، من جدول الفرع
    v_tbl := 'stock_' || r.code;
    if to_regclass('public.' || quote_ident(v_tbl)) is not null then
      execute format('select count(*), max(updated_at) from public.%I', v_tbl)
        into v_cnt, v_upd;
    else
      v_cnt := 0; v_upd := null;
    end if;
    v_meta := v_meta || jsonb_build_object(
                r.code, jsonb_build_object('count', v_cnt, 'updated', v_upd));

    -- ② الخريطة اللي الشاشة هتبني بيها أعمدتها
    v_brs := v_brs || jsonb_build_object(
               'code', r.code, 'name', r.name,
               'letter', r.letter, 'sort', r.sort_order);

    -- ③ أعمدة الفرع في نص الاستعلام — مرة واحدة، مش لكل صف
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'stock_flat'
                  and column_name = r.letter || '_q') then
      v_sel := v_sel || format(
        ', %L, jsonb_build_object(%L, %I, %L, %I, %L, %I)',
        r.letter, 'h', r.letter || '_h', 'q', r.letter || '_q', 'p', r.letter || '_p');
    else
      -- أعمدة الفرع لسه ماتعملتش في stock_flat → أصفار ظاهرة
      v_sel := v_sel || format(
        ', %L, jsonb_build_object(%L, false, %L, 0, %L, 0)', r.letter, 'h', 'q', 'p');
      raise notice '⚠️ فرع % (حرف %) مالوش أعمدة في stock_flat — بيرجع بأصفار', r.code, r.letter;
    end if;
  end loop;

  v_meta := v_meta || jsonb_build_object('branches', v_brs);

  execute 'select coalesce(jsonb_agg(jsonb_build_object('
          || '''c'', itm_code, ''n'', n, ''co'', co, ''u'', u, ''med'', med'
          || v_sel || ')), ''[]''::jsonb) from public.stock_flat'
    into v_items;

  return jsonb_build_object('meta', v_meta, 'items', v_items);
end $fn$;

-- الصلاحيات زي ما كانت **بالحرف**: الدالة كانت مكشوفة لـPUBLIC + anon
-- + authenticated. مش بضيّقها هنا — ده قرار أمني مستقل وله خطة لوحدها
-- (SECURITY_HANDOFF.md)، ولو ضيّقتها في ترحيل شكله «تحسين للفروع»
-- هتقع شاشة ومحدش يعرف السبب.
grant execute on function public.get_stock_summary() to public, anon, authenticated;

notify pgrst, 'reload schema';
