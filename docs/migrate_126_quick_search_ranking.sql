/* ============================================================
   بحث المخزون السريع: الاسم المطابق يطلع الأول
   ------------------------------------------------------------
   البلاغ: البحث عن «ديفارول» بيرجّع «برفان ديفا» و«دي ترول»
   و«ديبريفان» فوق، و«ديفارول1س امبول» سابع.

   تلات أسباب متداخلة، كلهم كانوا بيدّوا نفس الدرجة 0.95 فالترتيب
   بيرجع أبجدي:

   1) **% و _ في اسم الصنف كانوا بيشتغلوا كرموز بحث.** الشرط
      `x.w like y || '%'` بياخد كلمة من اسم الصنف كـpattern، و
      «ديبريفان 1 % 5 امبول» فيها كلمة «%» لوحدها → 'ديفارول' LIKE '%%'
      = صح دايمًا. أي صنف فيه % كان بيتطابق مع أي بحث.
      الحل: starts_with() — دالة مقارنة عادية مالهاش رموز.

   2) **المطابقة العكسية كانت بنفس قوة المطابقة الصحيحة.** كلمة
      الصنف «دي» أو «ديفا» بادئة لكلمة البحث «ديفارول» → 0.95، زي
      «ديفارول1س» اللي بتبدأ فعلًا بالمكتوب. دلوقتي: الصنف يبدأ
      بالمكتوب = 0.95، والعكس = 0.60 وبشرط الكلمة ≥ ٤ حروف (فـ«دي»
      مابقتش تتطابق أصلًا).

   3) **الاسم اللي بيبدأ بالمكتوب ماكانش ليه أفضلية** على اللي
      بيحتويه في النص. بقى 0.99 مقابل 0.95، وعند التساوي الاسم
      الأقصر الأول (ديفارول1س امبول قبل ديفارول1س امبول قديم).

   + شبكة أمان: لو مفيش ولا نتيجة قوية خالص، بنعرض أقرب الأسماء
     (≥ 0.25) بدل «لا نتائج» — عشان الغلطة الإملائية ما تبقاش
     طريق مسدود.

   الفلترة الأولية فضلت LIKE عشان تستفيد من فهرس الترايجرام، بس
   مع تهريب % و _ اللي المستخدم ممكن يكتبهم.
   القياس: نفس السرعة (273 مللي مقابل 290 للقديمة).
   ============================================================ */
create or replace function public.quick_search_stock(p_q text, p_limit integer default 20)
returns table(code text, name text, company text, unit text, med integer,
              m_q numeric, s_q numeric, b_q numeric, m_p numeric, q jsonb, sim real)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_q text := btrim(coalesce(p_q,''));
  qn  text;
  ws  text[];
begin
  if length(v_q) < 2 then return; end if;
  qn := ar_norm(v_q);
  ws := array(select w from regexp_split_to_table(qn, '\s+') w where length(w) > 1);
  if ws is null or array_length(ws,1) is null then ws := array[qn]; end if;

  perform set_limit(0.15);

  return query
  with cand as (
    select f.* from stock_flat f
     where starts_with(lower(f.itm_code), lower(v_q))
        or f.n_norm % qn
        or (select bool_or(f.n_norm like '%' || replace(replace(replace(w,'\','\'),'%','\%'),'_','\_') || '%')
              from unnest(ws) w)
     limit 1500
  ),
  w as (
    select c.*, t.mn, t.av, t.fw
    from cand c
    cross join lateral (
      select min(s) mn, avg(s) av, max(s) filter (where ord = 1) fw
      from (
        select x.ord,
               coalesce((select max(case
                           when y = x.w                                  then 1.00
                           when length(x.w) >= 3 and starts_with(y, x.w) then 0.95  -- الصنف بيبدأ بالمكتوب
                           when length(y)   >= 4 and starts_with(x.w, y) then 0.60  -- العكس: أضعف
                           else similarity(x.w, y) end)
                           from regexp_split_to_table(c.n_norm, '\s+') y), 0)::numeric s
          from unnest(ws) with ordinality x(w, ord)) z
    ) t
  ),
  sc as (
    select w.*, greatest(0.6*w.mn + 0.4*w.av,
             case when w.itm_code = v_q                           then 1.00
                  when starts_with(w.n_norm, qn)                  then 0.99   -- الاسم يبدأ بالمكتوب
                  when position(qn in w.n_norm) > 0               then 0.95   -- المكتوب جوّه الاسم
                  when starts_with(lower(w.itm_code), lower(v_q)) then 0.90
                  else 0 end::numeric) score
    from w
  ),
  g as (select sc.*, count(*) filter (where sc.score >= 0.45) over () n_strict from sc)
  select g.itm_code, g.n, g.co, g.u, g.med, g.m_q, g.s_q, g.b_q, g.m_p,
         (select jsonb_object_agg(bl.letter, jsonb_build_object(
                   'name', bl.name, 'sort', bl.sort_order,
                   'q', coalesce((to_jsonb(g) ->> (bl.letter || '_q'))::numeric, 0),
                   'p', coalesce((to_jsonb(g) ->> (bl.letter || '_p'))::numeric, 0)))
            from public.branch_letters() bl),
         (case when g.score >= 0.45 then g.score else g.fw * 0.5 end)::real
    from g
   where g.score >= 0.45
      or (g.n_strict < 5 and g.fw >= 0.90)
      or (g.n_strict = 0 and g.score >= 0.25)   -- شبكة أمان للغلطة الإملائية
   order by (g.score >= 0.45) desc, g.score desc, g.fw desc, length(g.n), g.n
   limit greatest(1, least(p_limit, 40));
end $function$;
