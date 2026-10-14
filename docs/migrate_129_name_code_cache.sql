/* ============================================================
   ترشيح مخزن الشراء: تخزين نتيجة مطابقة الاسم بالكود
   ------------------------------------------------------------
   suggest_purchase_sources كانت تالت أتقل حاجة على القاعدة:
   24,610 نداء × 236 م.ث = ١.٦ ساعة معالجة في ٤ أيام.

   القياس بيفرّق الاتنين بوضوح:
     صنف **بكود**  → 0.51 م.ث   (بحث مفهرس في أسعار المخازن)
     صنف **بالاسم** → 58.4 م.ث  (مطابقة تقريبية على ٢٩ ألف صنف)

   يعني الاسم أغلى ١١٥ مرة، والشاشة بتعيد نفس المطابقة لنفس الأسماء
   في كل مرة تتفتح.

   ⚠️ منطق المطابقة نفسه **ما اتلمسش** — دقّته حسّاسة ومتظبّطة على
   بيانات حقيقية. اللي اتعمل تخزين ناتجها بس.

   إبطال الكاش بعاملين مع بعض:
     • عدد أصناف stock_flat اتغيّر (صنف جديد أو اتشال) — ده السبب
       الواقعي الوحيد اللي بيخلّي نفس الاسم يطابق كود مختلف.
     • أو مرّ على السطر أكتر من ٧ أيام.
   العدد بيتقرا **مرة واحدة** لكل نداء مش لكل صف.

   والنتايج السلبية (مفيش كود مطابق) بتتخزّن برضه — دي بالذات أغلى
   حاجة لأنها بتدوّر في الـ٢٩ ألف وترجع فاضية.
   ============================================================ */

create table if not exists public.purchase_name_code_cache (
  name_key     text primary key,
  itm_code     text,
  matched_name text,
  sim          real,
  stock_n      integer     not null,
  computed_at  timestamptz not null default now()
);

/* الجدول داخلي: الدالة بتكتب فيه بصلاحية المالك (SECURITY DEFINER)،
   ومحدش من المستخدمين محتاج يوصّله مباشرة. */
revoke all on table public.purchase_name_code_cache from public, anon, authenticated;

create or replace function public.suggest_purchase_sources(p_rows jsonb)
returns table(k text, resolved_code text, matched_by text, matched_name text,
              match_sim real, status text, stores jsonb)
language plpgsql
volatile                     -- بقت VOLATILE عشان تكتب في الكاش
security definer
set search_path to 'public'
as $function$
DECLARE
  r jsonb; v_incode text; v_inname text; v_mname text; v_sim real; v_stores jsonb;
  v_key text;
  v_stock_n integer := (select count(*) from public.stock_flat);   -- مرة واحدة للنداء كله
  v_hit boolean;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) LOOP
    k := r->>'k';
    resolved_code := NULL; matched_by := NULL; matched_name := NULL; match_sim := NULL; status := NULL; stores := '[]'::jsonb;
    v_mname := NULL; v_sim := NULL; v_stores := '[]'::jsonb;
    v_incode := nullif(btrim(coalesce(r->>'code','')),'');
    -- كود كله أصفار (00/000...) = كود وهمي «بدون كود» → نتجاهله ونماتش بالاسم
    IF v_incode ~ '^0+$' THEN v_incode := NULL; END IF;
    v_inname := coalesce(r->>'name','');

    IF v_incode IS NOT NULL THEN
      resolved_code := v_incode; matched_by := 'code';
    ELSE
      v_key := btrim(v_inname);     -- المفتاح هو نفس المدخل بالحرف
      v_hit := false;

      IF v_key <> '' THEN
        SELECT c.itm_code, c.matched_name, c.sim, true
          INTO resolved_code, v_mname, v_sim, v_hit
          FROM public.purchase_name_code_cache c
         WHERE c.name_key = v_key
           AND c.stock_n = v_stock_n
           AND c.computed_at > now() - interval '7 days';
      END IF;

      IF NOT coalesce(v_hit,false) THEN
        SELECT s.itm_code, s.name, s.sim INTO resolved_code, v_mname, v_sim
        FROM public.suggest_stock_codes(v_inname, 1) s;

        IF v_key <> '' THEN
          INSERT INTO public.purchase_name_code_cache(name_key, itm_code, matched_name, sim, stock_n, computed_at)
          VALUES (v_key, resolved_code, v_mname, v_sim, v_stock_n, now())
          ON CONFLICT (name_key) DO UPDATE
            SET itm_code = excluded.itm_code, matched_name = excluded.matched_name,
                sim = excluded.sim, stock_n = excluded.stock_n, computed_at = excluded.computed_at;
        END IF;
      END IF;

      -- نرفض الماتش لو ضعيف أو لو رجّع كود وهمي (أصفار)
      IF resolved_code IS NOT NULL AND resolved_code !~ '^0+$' AND coalesce(v_sim,0) >= 0.3 THEN
        matched_by := 'name'; matched_name := v_mname; match_sim := v_sim;
      ELSE
        resolved_code := NULL; status := 'no_match';
      END IF;
    END IF;

    IF resolved_code IS NOT NULL THEN
      SELECT coalesce(jsonb_agg(jsonb_build_object(
                'store', t.store, 'price', t.price, 'discount', t.discount_perc, 'cost', round(t.cost::numeric,2)
              ) ORDER BY t.cost ASC NULLS LAST), '[]'::jsonb)
      INTO v_stores
      FROM (
        SELECT sip.store, sip.price, sip.discount_perc,
               sip.price * (1 - LEAST(GREATEST(coalesce(sip.discount_perc,0),0),100)/100.0) AS cost
        FROM public.store_item_prices sip
        WHERE sip.code = resolved_code AND coalesce(sip.code,'') !~ '^0+$'
          AND sip.available = true AND sip.price IS NOT NULL
      ) t;
      stores := v_stores;
      status := CASE WHEN jsonb_array_length(v_stores) > 0 THEN 'ok' ELSE 'not_available' END;
    END IF;

    RETURN NEXT;
  END LOOP;
END $function$;

revoke all on function public.suggest_purchase_sources(jsonb) from public, anon;
grant execute on function public.suggest_purchase_sources(jsonb) to authenticated;
