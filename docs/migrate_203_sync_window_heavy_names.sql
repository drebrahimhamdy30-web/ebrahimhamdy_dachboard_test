-- ═══════════════════════════════════════════════════════════════════
--  خطة الجولة بتدّي كمان أسماء الأكواد اللي بحثها بيجيب نص الكتالوج
-- ═══════════════════════════════════════════════════════════════════
--  الوركفلو الفرقي بيجيب رصيد كل كود اتغيّر بـ`itm_code_search`.
--  والبحث ده **جزئي**، فتكلفته بتعتمد على كام كود في الكتالوج فيه
--  النص ده — يعني على **الحروف مش الطول**. القياس على 27,821 كود
--  (2026-11-10):
--
--      الرقم الواحد 0–9   →  9,269 – 15,668 صنف   (نص الكتالوج)
--      'b'                →  34
--      'sr'               →  9
--      'z'                →  1
--
--  ⚠️ القاعدة القديمة «استبعد أقل من 4 حروف» كانت غلط في أساسها:
--     رمت **906 كود منهم 339 ليهم رصيد** — وفيهم `sr` (سرنجات 3 سم
--     كبار، رصيد 3,926) و`dw` (ماء مذيب، 570) و`z` (مناديل جيب، 168).
--     الأصناف دي بحثها أرخص من نص أكواد الأربع خانات.
--     **ماتبنيش قاعدة على الطول من غير ما تقيس.**
--
--  ── الحل للعشرة أرقام ──
--  eplus بتقبل `itm_name_ar_search`، والبحث بالاسم الكامل **انتقائي**:
--      '8' اكوا تشيك انستانت 50 شرايط سكر →  9,304 بالكود  ·  2 بالاسم
--      '4' ريفو 320 مجم 200 اقراص         →  9,781 بالكود  ·  1 بالاسم
--      '6' ريد اقراص 60 قرص               → 15,668 بالكود  ·  1 بالاسم
--
--  فالدالة بترجّع `heavy` = خريطة كود→اسم عربي للأكواد دي، والوركفلو
--  بيبدّل جسم النداء على أساسها. و«تقسيم» بيفلتر على الكود بالحرف في
--  الحالتين، فالنتيجة واحدة.
--
--  ⚠️ الاسم جاي من جدولنا، فلو الصنف اتسمّى تاني في eplus بعد آخر
--     مزامنة، البحث بالاسم مش هيلاقيه. عشان كده الوركفلو بيكتب
--     «مارجعش: <كود>» في سجل الجولة بدل ما يسكت.
--  ⚠️ الكود اللي مالوش اسم عندنا بيتأجّل للّقطة الكاملة وبيتكتب في
--     السجل كمان.
--
--  الكتالوج واحد لكل الفروع، فأول جدول في `p_branches` كفاية.
--  بيستبدل نسخة migrate_202 (نفس التوقيع، بزيادة مفتاح `heavy`).
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.stock_sync_window(
  p_branches        text[],
  p_overlap_minutes int default 10,
  p_max_hours       int default 6,
  p_cold_hours      int default 2
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_tbl     text;
  v_first   text;
  v_max     timestamptz;
  v_last    timestamptz;
  v_oldest  text;
  v_since   timestamptz;
  v_capped  boolean := false;
  v_cold    boolean := false;
  v_heavy   jsonb;
  b         text;
begin
  if p_branches is null or array_length(p_branches, 1) is null then
    raise exception 'p_branches فاضية — لازم فرع واحد على الأقل';
  end if;

  foreach b in array p_branches loop
    select 'stock_' || bl.code into v_tbl
      from public.branch_letters() bl where bl.code = b;
    if v_tbl is null then
      raise exception 'فرع غير معروف: %', b;
    end if;
    if to_regclass('public.' || v_tbl) is null then
      raise exception 'جدول مخزون مش موجود: %', v_tbl;
    end if;
    if v_first is null then v_first := v_tbl; end if;

    execute format('select max(updated_at) from public.%I', v_tbl) into v_max;

    /* جدول ما اتلمسش خالص = بداية بارد. ماينفعش ناخده كأقدم ختم
       وإلا النافذة بتبقى من الأزل. */
    if v_max is null then
      v_cold := true;
    elsif v_last is null or v_max < v_last then
      v_last   := v_max;
      v_oldest := b;
    end if;
  end loop;

  if v_last is null then
    v_cold  := true;
    v_since := now() - make_interval(hours => p_cold_hours);
  else
    /* تغطية راجعة: الجولة بتجلب وبتكتب على مدى ثواني/دقايق، فالختم
       بيتأخّر شوية عن لحظة الجلب الحقيقية. */
    v_since := v_last - make_interval(mins => p_overlap_minutes);
  end if;

  if now() - v_since > make_interval(hours => p_max_hours) then
    v_since  := now() - make_interval(hours => p_max_hours);
    v_capped := true;
  end if;

  /* الأكواد اللي البحث بيها بيرجّع نص الكتالوج → بترجع بالاسم */
  execute format(
    'select coalesce(jsonb_object_agg(itm_code, itm_name_ar), ''{}''::jsonb) '
    'from (select distinct on (itm_code) itm_code, itm_name_ar '
    '        from public.%I '
    '       where itm_code ~ ''^[0-9]$'' and coalesce(itm_name_ar, '''') <> '''' '
    '       order by itm_code) z', v_first) into v_heavy;

  return jsonb_build_object(
    'since_cairo', to_char(v_since at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI:SS'),
    'since',       v_since,
    'last_write',  v_last,
    'oldest',      v_oldest,
    'gap_minutes', round(extract(epoch from (now() - v_since)) / 60.0),
    'capped',      v_capped,
    'cold',        v_cold,
    'heavy',       coalesce(v_heavy, '{}'::jsonb),
    'branches',    to_jsonb(p_branches),
    'at',          now()
  );
end $$;

comment on function public.stock_sync_window(text[], int, int, int) is
  'خطة جولة المزامنة الفرقية: النافذة = أقدم آخر-كتابة ناقص تغطية بصيغة eplus (قاهرة naive)، و heavy = أسماء الأكواد اللي البحث بيها بيرجّع نص الكتالوج فبتتجاب بالاسم. capped=النافذة اتقصّت فاللقطة الليلية لازمة.';

/* الدالة تُنادى بالمفتاح الخدمي من n8n بس — مش من المتصفح.
   راجع [[anon-key-lockdown]]: PUBLIC بياخد EXECUTE افتراضيًا. */
revoke all on function public.stock_sync_window(text[], int, int, int) from public;
revoke all on function public.stock_sync_window(text[], int, int, int) from anon;
grant execute on function public.stock_sync_window(text[], int, int, int) to service_role;
