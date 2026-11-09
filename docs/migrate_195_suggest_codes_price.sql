/* ═══════════════════════════════════════════════════════════════════
   اقتراح الكود من المخزون: إضافة سعر البيع
   ═══════════════════════════════════════════════════════════════════
   مودال «اقتراح كود» في شاشة أسعار المخازن بيعرض الاسم والكود ونسبة
   التشابه. لما الاقتراحات تبقى متقاربة (أسماء بيوبلانس كلها حوالي
   ٢٣–٢٤٪) النسبة لوحدها مابتفرّقش — **السعر هو اللي بيحسم**: الصنف
   اللي سعره قريب من سعر المورّد هو غالبًا المطابق.

   ── السعر واحد ولا بالفرع؟ ───────────────────────────────────────
   `stock_flat` فيها سعر لكل فرع (`m_p`/`s_p`/`b_p`/`f_p`). فحصت
   ٢٩٬٢٤٧ صنف: **٥٣ صنف بس (٠.٣٪) سعرهم مختلف بين الفروع**. فالعرض
   رقم واحد، ولو اختلف بيتعرض مدى (من–إلى) بدل ما نختار فرع ونسكت.
   عشان كده بترجع `price_lo` و`price_hi` مش رقم واحد.

   ⚠️ الصفر في أعمدة السعر معناه «الصنف مش في الفرع ده» مش «ببلاش» —
      فبيتشال قبل حساب المدى، وإلا كل صنف موجود في فرع واحد كان
      هيبان مداه «٠ – ٦٦٠».

   ⚠️ تغيير `RETURNS TABLE` مايتعملش بـREPLACE — لازم DROP وCREATE،
      والصلاحيات بتتمسح معاها فلازم ترجع (authenticated + service_role
      زي ما كانت، وanon مسحوبة).

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

drop function if exists public.suggest_stock_codes(text, integer);

create or replace function public.suggest_stock_codes(p_name text, p_limit integer)
returns table(itm_code text, name text, company text, sim real,
              price_lo numeric, price_hi numeric)
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  clean text := coalesce(p_name,'');
  q text; qsq text; w1 text; w1s text; qn text[]; qkw text[];
begin
  clean := regexp_replace(clean, '[0-9٠-٩]+\s*(شريط|شرائط)', ' ', 'g');
  clean := regexp_replace(clean, '[0-9٠-٩]+(\.[0-9]+)?\s*ج(?![مرا])', ' ', 'g');
  clean := regexp_replace(clean, '[*]+', ' ', 'g');
  clean := regexp_replace(clean, '(سعر جديد|سعر|س ج|قديم|ثلاجه|ثلاجة)', ' ', 'g');

  q   := ar_norm(clean);
  qsq := replace(ar_norm(clean), ' ', '');
  w1  := split_part(ar_norm(clean), ' ', 1);
  w1s := sort_letters(split_part(ar_norm(clean), ' ', 1));
  qn  := num_tokens(clean);
  qkw := ar_key_words(clean);
  if q = '' then return; end if;

  perform set_limit(0.25);
  return query
  with cand as (
    select f.itm_code, f.n, f.co, f.n_fw, f.n_fw_sorted, f.n_norm, f.n_sq, f.n_nums, f.n_kw,
           f.m_p, f.s_p, f.b_p, f.f_p,
           greatest(similarity(f.n_norm, q), similarity(f.n_sq, qsq), similarity(f.n_fw, w1)) as pre
    from stock_flat f
    where f.n_norm % q or f.n_sq % qsq or f.n_fw % w1
    order by pre desc
    limit 150
  ),
  sc as (
    select c.itm_code, c.n, c.co,
      (( 0.6 * greatest( similarity(c.n_fw, w1),
                         similarity(c.n_fw_sorted, w1s),
                         similarity(left(c.n_sq, length(w1)), w1) )
       + 0.4 * greatest( similarity(c.n_norm, q), similarity(c.n_sq, qsq) ))
       * case when array_length(qn,1) is null then 1.0
              else 0.4 + 0.6 * ((select count(*) from unnest(qn) z where z = any(c.n_nums))::numeric
                                / array_length(qn,1)) end)::real as base,
      coalesce((select max(similarity(a,b)) from unnest(qkw) a, unnest(c.n_kw) b), 0)::real as kw,
      /* الصفر = مش موجود في الفرع، مش سعر */
      (select min(x) from unnest(array_remove(array[
         nullif(btrim(c.m_p::text),'')::numeric, nullif(btrim(c.s_p::text),'')::numeric,
         nullif(btrim(c.b_p::text),'')::numeric, nullif(btrim(c.f_p::text),'')::numeric],
         null)) x where x > 0) as p_lo,
      (select max(x) from unnest(array_remove(array[
         nullif(btrim(c.m_p::text),'')::numeric, nullif(btrim(c.s_p::text),'')::numeric,
         nullif(btrim(c.b_p::text),'')::numeric, nullif(btrim(c.f_p::text),'')::numeric],
         null)) x where x > 0) as p_hi
    from cand c
  ),
  m as (select sc.*, max(sc.base) over () as best from sc)
  select m.itm_code, m.n, m.co,
         (case when m.best < 0.38 then greatest(m.base, m.kw * 0.9::real) else m.base end)::real as sim,
         m.p_lo, m.p_hi
  from m
  order by (case when m.best < 0.38 then greatest(m.base, m.kw * 0.9::real) else m.base end) desc, m.n
  limit greatest(1, least(p_limit, 30));
end$fn$;

revoke all on function public.suggest_stock_codes(text, integer) from public, anon;
grant execute on function public.suggest_stock_codes(text, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
