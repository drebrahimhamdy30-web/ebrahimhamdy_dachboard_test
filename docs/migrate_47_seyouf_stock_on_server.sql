-- ═══════════════════════════════════════════════════════════════════
-- مخزون السيوف على السيرفر الذاتي + سدّ ثغرة «الجدول الجديد»
-- ═══════════════════════════════════════════════════════════════════
-- (آمن على القاعدتين — على السحابة كله موجود خلاص فبيبقى بلا مفعول)
--
-- اللي اتكشف (2026-09-25) بفحص السيرفر الذاتي عبر PostgREST:
--   • `branches` فيه السيوف          ✅
--   • `branches.letter`               ❌ مش موجود (ترحيل 46 لسه)
--   • `stock_flat.f_q`                ❌ مش موجود
--   • `stock_seyouf`                  ❌ **الجدول نفسه مش موجود**
--
--   الفرق بين ردّي PostgREST هو الدليل: `stock_mamora` بيرجّع 42501
--   (موجود، صلاحية ناقصة) و`stock_seyouf` بيرجّع PGRST205 (مش موجود).
--
-- ⚠️ ليه ترحيل 46 لوحده مش كفاية على السيرفر:
--   46 بيقرا العمود بـ`to_jsonb(row) ->> (letter||'_q')`. لو العمود
--   مش موجود، ده بيرجّع null → coalesce → **صفر**. يعني الشاشة هتعرض
--   السيوف بصفر في كل صنف **من غير أي خطأ**. فلازم 47 قبل أو مع 46.
--
-- ═══ السبب الجذري: المزامنة اليومية عمرها ما بتخلق جدول جديد ═══
--   الحلقة في `refresh_data_from_cloud.sql` بتلفّ على جداول `public`
--   المحلية وبتشترط إن يكون ليها نظير في `cloudsrc`:
--       select c.relname from pg_class c where n.nspname='public' ...
--         and exists (... n2.nspname='cloudsrc' and c2.relname=c.relname)
--   فجدول موجود على السحابة ومش موجود محليًا **مايدخلش الحلقة أصلًا**،
--   ومفيش ولا سطر skip في `cloud_sync_log` يقول إنه اتخطّى.
--   ده مش عيب خاص بالسيوف — أي جدول جديد على السحابة بيتوه بالساكت.
--   التقرير اللي بيكشف ده اتضاف في refresh_data_from_cloud.sql
--   (نفس الكوميت) — بيسجّل status='missing' لكل جدول سحابي مش محلي.
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ── ١) جدول مخزون السيوف ─────────────────────────────────────────
-- نسخة بنيوية من جدول فرع شغّال: نفس الأعمدة والفهارس والقيود
-- والافتراضيات. اتأكدنا من السحابة إن stock_seyouf و stock_mamora
-- متطابقين 22 عمود بصفر اختلاف، فالنسخ ده أمين.
create table if not exists public.stock_seyouf
  (like public.stock_mamora including all);

-- الصلاحيات تتنسخ من فرع شغّال كذلك — عشان مانفترضش سياسة قاعدة
-- معيّنة (الذاتي والسحابة مختلفين في الافتراضيات).
do $grants$
declare r record;
begin
  for r in
    select distinct grantee, privilege_type
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name = 'stock_mamora'
       and grantee <> current_user
  loop
    execute format('grant %s on public.stock_seyouf to %I', r.privilege_type, r.grantee);
  end loop;
end $grants$;

-- ── ٢) الجدول الأجنبي المقابل، عشان المزامنة تشوفه ───────────────
-- من غير ده المزامنة اليومية هتفضل تتخطّاه: الحلقة بتشترط نظير
-- في cloudsrc. IMPORT بيوقع لو الجدول الأجنبي موجود، فبنحرسه.
do $fdw$
begin
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'cloudsrc' and c.relname = 'stock_seyouf'
  ) then
    execute 'import foreign schema public limit to (stock_seyouf)
             from server cloud into cloudsrc';
    raise notice '✓ cloudsrc.stock_seyouf اتضاف';
  else
    raise notice '· cloudsrc.stock_seyouf موجود خلاص';
  end if;
exception when others then
  -- السحابة ممكن تكون مش واصلة وقت الترحيل — ده مايوقفش الباقي،
  -- بس لازم يبان عشان محدش يفتكر إن المزامنة هتشتغل.
  raise warning '⚠️ ماقدرتش أضيف cloudsrc.stock_seyouf: % — المزامنة اليومية هتتخطّى الجدول لحد ما ده يتصلّح', sqlerrm;
end $fdw$;

-- ── ٣) أعمدة السيوف في stock_flat ────────────────────────────────
alter table public.stock_flat add column if not exists f_h boolean;
alter table public.stock_flat add column if not exists f_q numeric;
alter table public.stock_flat add column if not exists f_p numeric;

-- ── ٤) الدالتين اللي بيبنوا ويقروا stock_flat ────────────────────
-- ⚠️ الفروع الأربعة مكتوبين بالإيد هنا **بالقصد**: الهدف من الترحيل
--    ده إن السيرفر يبقى **مطابق للسحابة بالحرف** عشان نقدر نقارن.
--    تحويلهم لـbranches.letter بند مستقل — refresh_stock_flat بتبني
--    كاش المخزون كله، ولو وقعت المخزون كله بيقع في كل الفروع، فمش
--    من الحكمة نغيّر بنيتها في نفس خطوة سدّ الفرق.

create or replace function public.get_stock_summary()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'meta', jsonb_build_object(
      'mamora', jsonb_build_object('count', (select count(*) from stock_mamora), 'updated', (select max(updated_at) from stock_mamora)),
      'san',    jsonb_build_object('count', (select count(*) from stock_san),    'updated', (select max(updated_at) from stock_san)),
      'bishr',  jsonb_build_object('count', (select count(*) from stock_bishr),  'updated', (select max(updated_at) from stock_bishr)),
      'seyouf', jsonb_build_object('count', (select count(*) from stock_seyouf), 'updated', (select max(updated_at) from stock_seyouf))
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'c', itm_code, 'n', n, 'co', co, 'u', u, 'med', med,
        'm', jsonb_build_object('h', m_h, 'q', m_q, 'p', m_p),
        's', jsonb_build_object('h', s_h, 'q', s_q, 'p', s_p),
        'b', jsonb_build_object('h', b_h, 'q', b_q, 'p', b_p),
        'f', jsonb_build_object('h', f_h, 'q', f_q, 'p', f_p)
      )) from stock_flat
    ), '[]'::jsonb)
  );
$fn$;

create or replace function public.refresh_stock_flat()
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare cur timestamptz; prev timestamptz;
begin
  select greatest(
           (select max(updated_at) from stock_mamora),
           (select max(updated_at) from stock_san),
           (select max(updated_at) from stock_bishr),
           (select max(updated_at) from stock_seyouf)
         ) into cur;
  select src_max into prev from stock_flat_meta where id = 1;
  if prev is not null and cur is not distinct from prev then return; end if;

  truncate public.stock_flat;
  insert into public.stock_flat
    (itm_code, n, co, u, med, m_h, m_q, m_p, s_h, s_q, s_p, b_h, b_q, b_p, f_h, f_q, f_p,
     n_norm, n_fw, n_fw_sorted)
  select base.itm_code, base.n, base.co, base.u, base.med,
         base.m_h, base.m_q, base.m_p, base.s_h, base.s_q, base.s_p,
         base.b_h, base.b_q, base.b_p, base.f_h, base.f_q, base.f_p,
         ar_norm(base.n),
         split_part(ar_norm(base.n),' ',1),
         sort_letters(split_part(ar_norm(base.n),' ',1))
  from (
    select c.itm_code,
      coalesce(m.itm_name_ar, s.itm_name_ar, b.itm_name_ar, f.itm_name_ar, '') as n,
      coalesce(m."Company_Name_Ar", s."Company_Name_Ar", b."Company_Name_Ar", f."Company_Name_Ar", '') as co,
      coalesce(m.u_name_big, s.u_name_big, b.u_name_big, f.u_name_big, '') as u,
      coalesce(
        case when m.itm_ismedicine ~ '^[0-9]+$' then m.itm_ismedicine::int end,
        case when s.itm_ismedicine ~ '^[0-9]+$' then s.itm_ismedicine::int end,
        case when b.itm_ismedicine ~ '^[0-9]+$' then b.itm_ismedicine::int end,
        case when f.itm_ismedicine ~ '^[0-9]+$' then f.itm_ismedicine::int end, 0) as med,
      (m.itm_code is not null) as m_h,
      case when m.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$' then m.sto_qty_big::numeric else 0 end as m_q,
      case when m.itm_sell_price_big ~ '^-?[0-9]+(\.[0-9]+)?$' then m.itm_sell_price_big::numeric else 0 end as m_p,
      (s.itm_code is not null) as s_h,
      case when s.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$' then s.sto_qty_big::numeric else 0 end as s_q,
      case when s.itm_sell_price_big ~ '^-?[0-9]+(\.[0-9]+)?$' then s.itm_sell_price_big::numeric else 0 end as s_p,
      (b.itm_code is not null) as b_h,
      case when b.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$' then b.sto_qty_big::numeric else 0 end as b_q,
      case when b.itm_sell_price_big ~ '^-?[0-9]+(\.[0-9]+)?$' then b.itm_sell_price_big::numeric else 0 end as b_p,
      (f.itm_code is not null) as f_h,
      case when f.sto_qty_big ~ '^-?[0-9]+(\.[0-9]+)?$' then f.sto_qty_big::numeric else 0 end as f_q,
      case when f.itm_sell_price_big ~ '^-?[0-9]+(\.[0-9]+)?$' then f.itm_sell_price_big::numeric else 0 end as f_p
    from (
      select itm_code from stock_mamora
      union select itm_code from stock_san
      union select itm_code from stock_bishr
      union select itm_code from stock_seyouf
    ) c
    left join stock_mamora m on m.itm_code = c.itm_code
    left join stock_san    s on s.itm_code = c.itm_code
    left join stock_bishr  b on b.itm_code = c.itm_code
    left join stock_seyouf f on f.itm_code = c.itm_code
  ) base;

  insert into public.stock_flat_meta(id, src_max) values (1, cur)
  on conflict (id) do update set src_max = excluded.src_max;

  perform public.refresh_purchase_orders();
end;
$fn$;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════
-- الفحص بعد التشغيل — لازم تشوف نتيجة الأربعة
-- ═══════════════════════════════════════════════════════════════════
select 'stock_seyouf موجود' as الفحص,
       (to_regclass('public.stock_seyouf') is not null)::text as النتيجة
union all
select 'cloudsrc.stock_seyouf موجود',
       exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
               where n.nspname='cloudsrc' and c.relname='stock_seyouf')::text
union all
select 'stock_flat.f_q موجود',
       exists(select 1 from information_schema.columns
               where table_schema='public' and table_name='stock_flat' and column_name='f_q')::text
union all
select 'صفوف stock_seyouf (صفر لحد أول مزامنة)',
       (select count(*)::text from public.stock_seyouf);
