-- ═══════════════════════════════════════════════════════════════════
-- بحث الهيدر في المخزون: تسجيل بالكلمة بدل تشابه الجملة كلها
-- ═══════════════════════════════════════════════════════════════════
-- المشكلة: البحث عن «ساتر رضاعه» كان بيرجّع 25 نتيجة، أول اتنين بس صح
-- والباقي «سماعه روزماكس» و«جهاز ضغط ساعه» و«روج سائل تشاو».
--
-- السبب: الدالة كانت بتقارن الجملة كلها كحروف متلاصقة بعتبة
-- set_limit(0.1) — عتبة منخفضة جدًا. الدرجات الفعلية كانت:
--   ساتر رضاعه بيبي ............... 0.900
--   كنجارو سواتر مخدات رضاعه ...... 0.200   ← نتيجة صح
--   سماعه روزماكس ................. 0.190   ← جنك
--   جهاز ضغط ساعه روزماكس ......... 0.179   ← جنك
-- يعني النتيجة الصح التانية فوق الجنك بشعرة — عتبة أعلى لوحدها
-- كانت هتشيلها معاهم.
--
-- الحل: الدرجة تتحسب **لكل كلمة من كلمات البحث على حدة**:
--   كلمة كاملة مطابقة = 1.00 · بداية كلمة = 0.95 · غير كده = التشابه
-- وبعدين  score = 0.6 * أقل كلمة + 0.4 * متوسط الكلمات
-- فالاسم لازم يغطي **كل** كلمات البحث مش حروف متناثرة منها.
-- النتيجة: «ساتر رضاعه» رجّعت 2 بالظبط.
--
-- ⚠️ المطابقة على مستوى الكلمة مش جزء من كلمة عن قصد: «ابيكساتراك»
--    جوّاه حروف «ساتر» ككتلة، وكان بيظهر لما جرّبت LIKE '%ساتر%'.
--
-- ملاذ: لو مفيش ولا نتيجة قوية (كلهم تحت 0.45) — زي «شاش طبي» واحنا
-- مسمّينه «شاش 10 سم» — بيرجّع اللي **أول كلمة** في البحث مطابقة فيه،
-- عشان مايرجعش صفر. وبيتقيّد بـ«أقل من 5 نتائج قوية» عشان البحث
-- الدقيق يفضل نضيف.
--
-- السرعة: 577ms → 307ms. الفرق إن الفلتر بقى على العمود المحسوب
-- n_norm (عليه فهرس GIN) بدل ar_norm(n) اللي كانت بتتحسب لكل صف.
--
-- مفيش أي تعديل في الصفحات — delivery/app.html بينادي نفس الاسم.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.quick_search_stock(p_q text, p_limit integer default 20)
returns table(code text, name text, company text, unit text, med integer,
              m_q numeric, s_q numeric, b_q numeric, m_p numeric, q jsonb, sim real)
language plpgsql stable security definer set search_path to 'public' as $fn$
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
     where f.n_norm % qn
        or f.n_norm like '%' || ws[1] || '%'
        or f.itm_code ilike v_q || '%'
     limit 1200
  ),
  w as (
    select c.*, t.mn, t.av, t.fw
    from cand c
    cross join lateral (
      select min(s) mn, avg(s) av, max(s) filter (where ord = 1) fw
      from (
        select x.ord,
               coalesce((select max(case when y = x.w then 1.00
                                         when length(x.w) >= 3 and (y like x.w || '%' or x.w like y || '%') then 0.95
                                         else similarity(x.w, y) end)
                           from regexp_split_to_table(c.n_norm, '\s+') y), 0)::numeric s
          from unnest(ws) with ordinality x(w, ord)) z
    ) t
  ),
  sc as (
    select w.*, greatest(0.6*w.mn + 0.4*w.av,
             case when w.itm_code = v_q               then 1.00
                  when w.n_norm like '%' || qn || '%'  then 0.95
                  when w.itm_code ilike v_q || '%'     then 0.90
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
   order by (g.score >= 0.45) desc, g.score desc, g.fw desc, g.n
   limit greatest(1, least(p_limit, 40));
end $fn$;

comment on function public.quick_search_stock(text,integer) is
  'بحث الهيدر السريع في المخزون. الدرجة بتتحسب لكل كلمة بحث على حدة (كلمة كاملة / بداية كلمة / تشابه) ثم 0.6*أقل كلمة + 0.4*المتوسط. لو مفيش نتيجة قوية بيرجع اللي أول كلمة فيه مطابقة.';

-- فحص بعد التشغيل (المتوقع: صفّين بالظبط):
--   select name, round(sim::numeric,2) from quick_search_stock('ساتر رضاعه', 25);
