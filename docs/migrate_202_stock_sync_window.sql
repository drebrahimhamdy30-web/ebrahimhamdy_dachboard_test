-- ═══════════════════════════════════════════════════════════════════
--  نافذة المزامنة الفرقية تتحسب من **آخر كتابة ناجحة** مش من الساعة
-- ═══════════════════════════════════════════════════════════════════
--  الوركفلو الفرقي (docs/n8n_stock_incremental.json) كان بيسأل eplus
--  «مين اتغيّر من `$now - N ساعة`». ودي فيها عيب صامت:
--
--    الجولة 12:00 نجحت · الجولة 13:00 وقعت · الجولة 14:00 بتسأل من
--    13:00 — فالساعة من 12 لـ13 **مامسحهاش حد**، وأصنافها بتفضل
--    بأرصدة قديمة لحد اللقطة الليلية. والنافذة لو ساعة بالظبط يبقى
--    مفيش ولا دقيقة تغطية.
--
--  الحل: الوركفلو ماينفعش يخمّن — يسأل القاعدة **البيانات وصلت لحد
--  إمتى**. `upsert_branch_stock` بيختم `updated_at` على كل صف بيكتبه،
--  فأقصى `updated_at` في جدول الفرع = لحظة آخر جولة ناجحة. فالجولة
--  الواقعة بتتلحق **بالظبط** في الجولة اللي بعدها بلا نافذة واسعة.
--
--  بترجّع التاريخ **جاهز بصيغة eplus** — توقيت القاهرة naive بشكل
--  `YYYY-MM-DD HH24:MI:SS` — عشان ماحدش في n8n يحوّل بإيده ويغلط
--  (السيرفر UTC والفرق ساعتين شتوي وتلاتة صيفي).
--
--  ⚠️ `p_branches` **كل الفروع المفتوحة للكتابة** مش فرع واحد: بناخد
--     **أقدم** ختم فيهم، عشان الفرع المتأخّر ما يفوتهوش حاجة.
--  ⚠️ السقف (`p_max_hours`): لو المزامنة واقفة من بدري، النافذة
--     الواسعة معناها آلاف الأكواد × ثانية = جولة بتتعدّى على اللي
--     بعدها. فبنقصّها وبنعلّم `capped` — واللقطة الليلية هي اللي
--     بتغطّي الباقي. الحقل ده **تحذير**، لازم يتقرا.
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
  v_max     timestamptz;
  v_last    timestamptz;
  v_oldest  text;
  v_since   timestamptz;
  v_capped  boolean := false;
  v_cold    boolean := false;
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
    /* تغطية راجعة بسيطة: الجولة بتجلب وبتكتب على مدى ثواني/دقايق،
       فالختم بيتأخّر شوية عن لحظة الجلب الحقيقية. */
    v_since := v_last - make_interval(mins => p_overlap_minutes);
  end if;

  if now() - v_since > make_interval(hours => p_max_hours) then
    v_since  := now() - make_interval(hours => p_max_hours);
    v_capped := true;
  end if;

  return jsonb_build_object(
    'since_cairo', to_char(v_since at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI:SS'),
    'since',       v_since,
    'last_write',  v_last,
    'oldest',      v_oldest,
    'gap_minutes', round(extract(epoch from (now() - v_since)) / 60.0),
    'capped',      v_capped,
    'cold',        v_cold,
    'branches',    to_jsonb(p_branches),
    'at',          now()
  );
end $$;

comment on function public.stock_sync_window(text[], int, int, int) is
  'نافذة المزامنة الفرقية = أقدم آخر-كتابة في جداول الفروع المطلوبة ناقص تغطية، بصيغة eplus (قاهرة naive). capped=النافذة اتقصّت فاللقطة الليلية لازمة.';

/* الدالة تُنادى بالمفتاح الخدمي من n8n بس — مش من المتصفح.
   راجع [[anon-key-lockdown]]: PUBLIC بياخد EXECUTE افتراضيًا. */
revoke all on function public.stock_sync_window(text[], int, int, int) from public;
revoke all on function public.stock_sync_window(text[], int, int, int) from anon;
grant execute on function public.stock_sync_window(text[], int, int, int) to service_role;
