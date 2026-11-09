-- ═══════════════════════════════════════════════════════════════════
--  معدل الاستهلاك: الشهر الجاري يتحسب بنسبة ما عدّى منه
-- ═══════════════════════════════════════════════════════════════════
--  المشكلة: المعدل = مجموع المبيعات ÷ عدد الشهور النشطة. والشهر
--  الجاري بيتعدّ **شهر كامل** وهو لسه 8 أيام — فالمقام أكبر من الزمن
--  اللي البسط بيغطّيه، والمعدل بيطلع أقل من الواقع بشكل منهجي.
--
--  قياس حقيقي 2026-11-09 (المعمورة) — «سرنجات 3 سم كبار» كود sr:
--    أغسطس 2,270 · سبتمبر 2,225 · أكتوبر 2,260 · نوفمبر 666 (8 أيام)
--    المعدل الحالي = 22,958 ÷ 11 = **2,087** — رقم الصنف عمره ما باعه.
--    الصح                = 22,958 ÷ 10.27 = **2,236**  (+7%)
--
--  والخطأ بيتغيّر حسب يوم الشهر اللي بتفتح فيه الشاشة:
--    يوم 1 → −9%  ·  يوم 8 → −6.6%  ·  يوم 15 → −4.5%  ·  يوم 30 → 0%
--  يعني أول الشهر — وقت الطلبيات بالظبط — هو أسوأ وقت.
--  و137 صنف مبيعاتهم بس في الشهر الجاري معدلهم أقل بـ73%.
--
--  العلاج: المقام = عدد الشهور الكاملة النشطة + **وزن** الشهر الجاري
--  (نسبة ما عدّى منه)، والبسط بيتفلتر عشان يطابق المقام بالظبط.
--
--  ── الوزن بييجي من ختم البيانات نفسها ──
--  أحدث `updated_at` في monthly_sales للشهر الجاري، مش من now().
--  السبب: لو المزامنة تأخرت يومين، المقام لازم يطابق الفترة اللي
--  البيانات فعلًا بتغطّيها — مش الفترة اللي الساعة بتقولها.
--  (اتأكدت 2026-11-09: كل الـ5,092 صف بتاع 11-2026 ليهم **ختم واحد**
--   = الشهر بيتمسح ويتكتب كامل كل جولة، فالختم صادق. راجع ذاكرة
--   sync-timestamp-lies — فيه أعمدة وقت تكدب، وده مش واحد منها.)
--
--  ── حارس أول الشهر ──
--  لو عدّى أقل من 20% من الشهر (≈6 أيام) الشهر الجاري **يتشال خالص**
--  من البسط والمقام. القسمة على 3 أيام بتضخّم المعدل 10 أضعاف وتطلب
--  بضاعة على ضجيج — والخطأ ده بيتكلّف رأس مال واقف، أما تأخير 6 أيام
--  على صنف جديد بيتكلّف لا حاجة.
--
--  ── مفيش قيمة بتبقى صفر ──
--  لو الوزن صفر (أول 6 أيام) والصنف **كل** تاريخه هو الشهر الجاري،
--  يبقى مالوش لا بسط ولا مقام. الحالة دي بترجع للسلوك القديم بالحرف
--  (÷ عدد الشهور النشطة) عشان مانخلّيش معدله صفر فجأة أول كل شهر.
--
--  ⚠️ بعد اليوم السادس الصنف الجديد ده بياخد النسبة زي أي صنف تاني —
--  وده **المقصود** مش استثناء: الـ137 صنف اللي كل مبيعاتهم في الشهر
--  الجاري كان معدلهم أقل من الحقيقة بـ73%. المقاس 2026-11-09: صنف
--  باع 2 علبة في 8.5 يوم معدله بقى 7.1 بدل 2.
--  (الصنف اللي شهر واحد + فاتورة واحدة لسه مقفول على 1 بقاعدة الشذوذ.)
--
--  ماتغيّرش: `act_` (عدد الشهور النشطة) بيفضل عدد صحيح بالشهر الجاري
--  كشهر كامل — عشان شرائح `category_rate_tiers` (active_min) وقاعدة
--  الشذوذ (شهر واحد + فاتورة واحدة) تتصرف زي ما هي بالحرف.
--  التغيير في **المقام** بس.
-- ═══════════════════════════════════════════════════════════════════

-- ── (١) الشهر الجاري ووزنه ──────────────────────────────────────────
create or replace function public.current_sales_month()
returns text
language sql stable
set search_path to 'public'
as $$ select to_char(now() at time zone 'Africa/Cairo', 'MM-YYYY') $$;

comment on function public.current_sales_month() is
  'اسم الشهر الجاري بصيغة monthly_sales (MM-YYYY) بتوقيت القاهرة.';

create or replace function public.current_month_weight()
returns numeric
language plpgsql stable
set search_path to 'public'
as $$
declare
  /* أقل نسبة نثق فيها: تحتها الشهر الجاري يتشال خالص */
  c_min constant numeric := 0.20;
  v_cur text := public.current_sales_month();
  v_mk  timestamp;   -- ختم البيانات بتوقيت القاهرة
  v_m0  timestamp;   -- أول الشهر
  v_w   numeric;
begin
  select (max(updated_at)) at time zone 'Africa/Cairo'
    into v_mk
    from public.monthly_sales
   where month = v_cur;

  if v_mk is null then return 0; end if;
  /* ختم بره الشهر الجاري = حاجة غريبة؛ ماناخدش الشهر خالص */
  if to_char(v_mk, 'MM-YYYY') <> v_cur then return 0; end if;

  v_m0 := date_trunc('month', v_mk);
  v_w  := extract(epoch from (v_mk - v_m0))
        / extract(epoch from ((v_m0 + interval '1 month') - v_m0));

  if v_w < c_min then return 0; end if;
  return least(v_w, 1);
end $$;

comment on function public.current_month_weight() is
  'وزن الشهر الجاري (0..1) = نسبة ما عدّى منه لحد ختم بيانات monthly_sales. صفر لو عدّى أقل من 20%.';

revoke all on function public.current_sales_month()  from public;
revoke all on function public.current_month_weight() from public;
grant execute on function public.current_sales_month()  to authenticated, service_role;
grant execute on function public.current_month_weight() to authenticated, service_role;

-- ── (٢) المقام في get_consumption_rates ─────────────────────────────
do $mig$
declare
  src  text := pg_get_functiondef('public.get_consumption_rates()'::regprocedure);
  nsrc text;
  a text; b text;
  function_marker constant text := 'curw_';

  procedure_count int;

  /* عدّاد تكرار نص جوّه نص — عشان مانستبدلش حاجة بتتكرر */
  n int;
begin
  if position(function_marker in src) > 0 then
    raise notice 'migrate_197: get_consumption_rates متعدّلة قبل كده — تخطّي';
    return;
  end if;

  nsrc := src;

  /* ── (أ) أعمدة الوزن في CTE الـbase (الفرع موجود في monthly_sales) */
  a := $a$      f_base := f_base
        || ', sum(ms.' || quote_ident(r.code) || ') sum_' || r.code
        || ', count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) act_' || r.code;$a$;
  b := $b$      f_base := f_base
        || ', sum(ms.' || quote_ident(r.code) || ') sum_' || r.code
        || ', sum(ms.' || quote_ident(r.code) || ') filter (where ms.month <> g.cm or g.w > 0) sumw_' || r.code
        || ', count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) act_' || r.code
        || ', count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0 and ms.month <> g.cm) actp_' || r.code
        || ', max(case when ms.month = g.cm and ms.' || quote_ident(r.code) || ' > 0 then g.w else 0 end) curw_' || r.code;$b$;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/أ: لقيت % نسخة من نقطة الحقن', n; end if;
  nsrc := replace(nsrc, a, b);

  /* ── (ب) نفس الأعمدة لفرع مش موجود في monthly_sales */
  a := $a$      f_base := f_base
        || ', 0::numeric sum_' || r.code
        || ', 0::bigint  act_' || r.code;$a$;
  b := $b$      f_base := f_base
        || ', 0::numeric sum_' || r.code
        || ', 0::numeric sumw_' || r.code
        || ', 0::bigint  act_' || r.code
        || ', 0::bigint  actp_' || r.code
        || ', 0::numeric curw_' || r.code;$b$;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/ب: لقيت % نسخة من نقطة الحقن', n; end if;
  nsrc := replace(nsrc, a, b);

  /* ── (ج) القسمة: شهور كاملة + وزن الجاري، وfallback للسلوك القديم */
  a := $a$    f_rate := f_rate
      || ', case when b.act_' || r.code || ' > 0'
      || '       then b.sum_' || r.code || '::numeric / b.act_' || r.code
      || '       else 0 end r_' || r.code$a$;
  b := $b$    f_rate := f_rate
      || ', case when (b.actp_' || r.code || ' + b.curw_' || r.code || ') > 0'
      || '       then b.sumw_' || r.code || '::numeric / (b.actp_' || r.code || ' + b.curw_' || r.code || ')'
      || '       when b.act_' || r.code || ' > 0'
      || '       then b.sum_' || r.code || '::numeric / b.act_' || r.code
      || '       else 0 end r_' || r.code$b$;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/ج: لقيت % نسخة من نقطة الحقن', n; end if;
  nsrc := replace(nsrc, a, b);

  /* ── (د) CTE الوزن + ضمّه لجدول الـbase */
  a := $a$    || '    from monthly_sales ms group by ms.itm_code'$a$;
  b := $b$    || '    from monthly_sales ms cross join wgt g group by ms.itm_code'$b$;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/د: لقيت % نسخة من نقطة الحقن', n; end if;
  nsrc := replace(nsrc, a, b);

  /* CTE الـwgt نفسه — الدالة ممكن تكون بـamap/bills قبل base
     (السحابة بعد migrate_98) أو base أول CTE (migrate_86) */
  a := $a$    || '), base as ('$a$;
  if position(a in nsrc) > 0 then
    b := $b$    || '), wgt as ('
    || '  select public.current_month_weight() w, public.current_sales_month() cm'
    || '), base as ('$b$;
  else
    a := $a$       'with base as ('$a$;
    b := $b$       'with wgt as ('
    || '  select public.current_month_weight() w, public.current_sales_month() cm'
    || '), base as ('$b$;
  end if;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/هـ: لقيت % نسخة من نقطة الحقن', n; end if;
  nsrc := replace(nsrc, a, b);

  if nsrc = src then raise exception 'migrate_197: الاستبدال ماغيّرش حاجة'; end if;
  execute nsrc;

  select count(*) into procedure_count
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'get_consumption_rates';
  if procedure_count <> 1 then
    raise exception 'migrate_197: فيه % نسخة من get_consumption_rates', procedure_count;
  end if;
end $mig$;

-- ── (٣) نفس المقام في نافذة التفاصيل ────────────────────────────────
--  الشاشة بتفتح get_consumption_detail عشان تشرح الرقم. لو المقام
--  اتغيّر في الحساب وماتغيّرش في الشرح، النافذة تقول رقم تاني.
do $mig$
declare
  src  text := pg_get_functiondef('public.get_consumption_detail(text)'::regprocedure);
  nsrc text;
  a text; b text;
  n int;
  procedure_count int;
begin
  if position('g.cm' in src) > 0 then
    raise notice 'migrate_197: get_consumption_detail متعدّلة قبل كده — تخطّي';
    return;
  end if;

  nsrc := src;

  a := $a$      f_rate := f_rate
        || ', case when count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) > 0'
        || '       then sum(ms.' || quote_ident(r.code) || ')::numeric'
        || '          / count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0)'
        || '       else 0 end r_' || r.code$a$;
  b := $b$      f_rate := f_rate
        || ', case when (count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0 and ms.month <> g.cm)'
        || '             + coalesce(max(case when ms.month = g.cm and ms.' || quote_ident(r.code) || ' > 0 then g.w else 0 end), 0)) > 0'
        || '       then (sum(ms.' || quote_ident(r.code) || ') filter (where ms.month <> g.cm or g.w > 0))::numeric'
        || '          / (count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0 and ms.month <> g.cm)'
        || '             + coalesce(max(case when ms.month = g.cm and ms.' || quote_ident(r.code) || ' > 0 then g.w else 0 end), 0))'
        || '       when count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) > 0'
        || '       then sum(ms.' || quote_ident(r.code) || ')::numeric'
        || '          / count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0)'
        || '       else 0 end r_' || r.code$b$;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/تفاصيل-أ: لقيت % نسخة', n; end if;
  nsrc := replace(nsrc, a, b);

  a := $a$    || '    from srcs s'
    || '    left join monthly_sales ms on ms.itm_code = s.src'$a$;
  b := $b$    || '    from srcs s'
    || '    cross join (select public.current_month_weight() w,'
    || '                       public.current_sales_month() cm) g'
    || '    left join monthly_sales ms on ms.itm_code = s.src'$b$;
  n := (length(nsrc) - length(replace(nsrc, a, ''))) / length(a);
  if n <> 1 then raise exception 'migrate_197/تفاصيل-ب: لقيت % نسخة', n; end if;
  nsrc := replace(nsrc, a, b);

  if nsrc = src then raise exception 'migrate_197: تفاصيل — الاستبدال ماغيّرش حاجة'; end if;
  execute nsrc;

  select count(*) into procedure_count
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'get_consumption_detail';
  if procedure_count <> 1 then
    raise exception 'migrate_197: فيه % نسخة من get_consumption_detail', procedure_count;
  end if;
end $mig$;

-- ── (٤) فحص إن الدالة بتشتغل فعلًا (plpgsql مابيفحصش وقت الإنشاء) ──
do $$
declare v_n int; v_w numeric;
begin
  v_w := public.current_month_weight();
  raise notice 'وزن الشهر الجاري = %', v_w;
  select count(*) into v_n from public.get_consumption_rates();
  if v_n < 1000 then
    raise exception 'migrate_197: الدالة رجّعت % صف بس — في حاجة غلط', v_n;
  end if;
  raise notice 'get_consumption_rates رجّعت % صف', v_n;
end $$;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════
--  الرجوع للخلف
-- ═══════════════════════════════════════════════════════════════════
--  الترحيل ده surgical (بيعدّل نص الدالة الموجود)، فالرجوع = إعادة
--  تشغيل آخر ترحيل بيعرّف كل دالة من الأول — والاتنين فيهم
--  create or replace كامل مش استبدال نصّي:
--
--      docs/migrate_147_raw_rate_stays_raw.sql         → get_consumption_rates
--      docs/migrate_56_consumption_detail_branches.sql → get_consumption_detail
--
--  وبعدها  select public.refresh_consumption_rates();  عشان الجدول
--  المسطّح يرجع للأرقام القديمة.
--
--  ⚠️ الدالتين الجديدتين (current_sales_month / current_month_weight)
--     تفضل موجودة من غير ما تستخدمها حاجة — مش محتاجة حذف.
