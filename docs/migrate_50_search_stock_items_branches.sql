-- ═══════════════════════════════════════════════════════════════════
-- search_stock_items: كل الفروع في النتيجة وفي الترتيب
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- عيبين في الدالة القديمة:
--   ① بترجّع qty_m / qty_s / qty_b بس → شاشة «الحد الأدنى» كانت
--      بتعرض رصيد تلات فروع والسيوف مختفي.
--   ② **الأهم**: حافز الترتيب كان
--         case when coalesce(m_q,0)+coalesce(s_q,0)+coalesce(b_q,0) > 0
--              then 25 else 0 end
--      يعني صنف **موجود في السيوف بس** ماكانش بياخد الحافز وبينزل في
--      النتايج تحت أصناف مالهاش رصيد خالص. ده عيب ترتيب صامت — النتيجة
--      بتبان «شغّالة» وهي مرتّبة غلط.
--
-- الحل: الجزئين اللي بيعتمدوا على الفروع بيتبنوا نصًّا من جدول الفروع
--   (branches.letter) وبيتحقنوا في الاستعلام مرة واحدة قبل التنفيذ.
--
-- ⚠️ ليه `||` مش `format()` لجسم الاستعلام:
--   الاستعلام مليان `'%' || longt || '%'` للـLIKE. `format()` بيفسّر `%`
--   كمحدّد، فكان لازم كل واحدة تتكتب `%%` — مصدر أخطاء ماينفعش نجازف بيه
--   في دالة بحث شغّالة. الدمج بـ`||` مالوش المشكلة دي.
--   وأسماء الأعمدة جاية من `branches.letter` لصف فعّال + `quote_ident`،
--   يعني قايمة بيضا مش مدخلات مستخدم.
--
-- المفاتيح القديمة qty_m/qty_s/qty_b متسيبة للتوافق، والجديد `q`
-- مفاتيحه حروف الفروع وفيه الاسم والترتيب — زي quick_search_stock.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.search_stock_items(p_q text, p_limit integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_role text := coalesce(public.jwt_app_role(), '');
  v_pg   text := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role', '');
  q      text := btrim(coalesce(p_q, ''));
  nq     text;
  fw     text;
  longt  text;
  toks   text[];
  lim    int  := least(greatest(coalesce(p_limit, 12), 1), 30);
  v_rows jsonb;
  v_sum  text := '0';     -- مجموع أرصدة كل الفروع (للحافز)
  v_obj  text := '';      -- كائن q لكل فرع
  v_sql  text;
  r      record;
begin
  if v_pg <> 'service_role' and v_role = '' then
    return jsonb_build_object('success', false, 'error', 'لازم تسجّل دخول');
  end if;
  if length(q) < 2 then
    return jsonb_build_object('success', false, 'error', 'اكتب حرفين على الأقل');
  end if;

  nq    := public.ar_norm(q);
  toks  := (select array_agg(t) from unnest(string_to_array(nq, ' ')) t where length(t) > 1);
  fw    := split_part(nq, ' ', 1);
  longt := (select t from unnest(coalesce(toks, array[nq])) t order by length(t) desc limit 1);

  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'stock_flat'
                  and column_name = r.letter || '_q') then
      v_sum := v_sum || ' + coalesce(c.' || quote_ident(r.letter || '_q') || ',0)';
      v_obj := v_obj
        || ', ' || quote_literal(r.letter)
        || ', jsonb_build_object('
        || quote_literal('name') || ', ' || quote_literal(r.name) || ', '
        || quote_literal('sort') || ', ' || coalesce(r.sort_order, 999)::text || ', '
        || quote_literal('q')    || ', coalesce(x.' || quote_ident(r.letter || '_q') || ',0), '
        || quote_literal('p')    || ', coalesce(x.' || quote_ident(r.letter || '_p') || ',0))';
    end if;
  end loop;
  v_obj := ltrim(v_obj, ', ');

  v_sql :=
    'with cand as ('
    || '  select sf.* from stock_flat sf'
    || '   where ($1 ~ ''^[0-9]+$'' and (sf.itm_code = $1 or sf.itm_code like $1 || ''%''))'
    || '      or sf.n_norm ilike ''%'' || $3 || ''%'''
    || '      or sf.n_norm % $2'
    || '      or (length($4) > 2 and sf.n_fw % $4)'
    || '   limit 800'
    || '), scored as ('
    || '  select c.*,'
    || '         case'
    || '           when c.itm_code = $1 then 1000'
    || '           when $1 ~ ''^[0-9]+$'' and c.itm_code like $1 || ''%'' then 900'
    || '           when c.n_norm = $2 then 800'
    || '           when c.n_norm like $2 || ''%'' then 700'
    || '           when c.n_norm like ''%'' || $2 || ''%'' then 600'
    || '           when $5 is not null and (select bool_and(c.n_norm like ''%'' || t || ''%'') from unnest($5) t) then 500'
    || '           when length($4) > 2 and c.n_fw like $4 || ''%'' then 400'
    || '           else 0'
    || '         end'
    || '         + (greatest(similarity(c.n_norm, $2), similarity(c.n_fw, $4)) * 120)::int'
    || '         + case when (' || v_sum || ') > 0 then 25 else 0 end as score'
    || '    from cand c'
    || ')'
    || ' select coalesce(jsonb_agg(jsonb_build_object('
    || '   ''code'', x.itm_code, ''name'', x.n, ''unit'', x.u, ''company'', x.co, ''med'', x.med,'
    || '   ''qty_m'', coalesce(x.m_q,0), ''qty_s'', coalesce(x.s_q,0), ''qty_b'', coalesce(x.b_q,0)'
    || (case when v_obj = '' then '' else ', ''q'', jsonb_build_object(' || v_obj || ')' end)
    || ' ) order by x.score desc, x.n), ''[]''::jsonb)'
    || '  from (select * from scored order by score desc, n limit $6) x';

  execute v_sql into v_rows using q, nq, longt, fw, toks, lim;

  return jsonb_build_object('success', true, 'rows', v_rows);
end $fn$;

-- الصلاحيات زي ما كانت
revoke all on function public.search_stock_items(text, integer) from public, anon;
grant execute on function public.search_stock_items(text, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
