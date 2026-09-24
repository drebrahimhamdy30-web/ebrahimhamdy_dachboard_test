-- ═══════════════════════════════════════════════════════════════════
-- آخر ويبهوكين للجرد: jard_items و jard_stale_report → دوال القاعدة
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**: السحابة والسيرفر الذاتي)
--
-- ليه:
--   • دول آخر نقطتين من الجرد على n8n، والاتنين قراءة بس — بياخدوا
--     الفرع والفئة من الرابط وبينفّذوا SELECT على نفس جداول سوبابيز.
--   • مفتوحين بـallowedOrigins:"*" من غير أي مصادقة، وبكريدنشيال Postgres
--     مباشر. وفيهم لصق نصوص في SQL:
--         and f.branch = '{{ $('Resolve Branch').item.json.branch }}'
--     يعني حقن. هنا الباراميترات بتتمرّر كقيم، مش بتتلصق.
--
-- نفس الاستعلامات بالحرف — مفيش تغيير في المنطق ولا في النتيجة.
--
-- ⚠️⚠️ ماتعملش view على جداول المخزون ⚠️⚠️
--   النسخة الأولى من الملف ده عملت عرض v_branch_stock بيوحّد الجداول
--   التلاتة، عشان يبقى سطر واحد يتعدّل لما الجدول الموحّد ينزل.
--   ده **وقّف مزامنة المخزون في كل الفروع** يوم 2026-09-24.
--
--   السبب: ورك فلو المزامنة بيحدّث المخزون بالتبديل مش بالمسح:
--       rename stock_mamora → stock_mamora_old
--       create stock_mamora (الجديد من staging)
--       drop   stock_mamora_old
--   والـview في Postgres بيتسجّل كاعتماد على **الجدول نفسه مش اسمه**،
--   فبيتبعه في إعادة التسمية وبيمنع الـdrop:
--       cannot drop table stock_mamora_old because other objects depend on it
--
--   الحل: الاستعلام اتنقل جوّه الدالتين. **أجسام الدوال مش بتتسجّل
--   كاعتماد** في Postgres، فالتبديل بيعدّي عادي.
--   والملف ده بيعمل drop للview في آخره عشان إعادة تشغيله تنضّف بدل
--   ما ترجّع العطل.
-- ═══════════════════════════════════════════════════════════════════

-- ═══ ١) أصناف الجرد لفرع + فئة ══════════════════════════════════
-- بديل webhook/jard_items
--
-- المنطق زي n8n:
--   • fastmove       → الأصناف اللي كودها في jard_fastmove_codes
--   • أي فئة تانية   → الأصناف المعلّمة بالفئة دي في jard_category_flags
--   • في الحالتين: الرصيد > 0، واستبعاد اللي اتجرد خلال cycle_days،
--     وعدم تكرار الكود.
create or replace function public.get_jard_items(p_branch text, p_category text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role text  := coalesce(claims ->> 'role', '');
  v_br    text;
  v_cat   text := btrim(coalesce(p_category, ''));
  v_cycle integer;
  out_j   jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;

  v_br := public.jard_canon_branch(p_branch);
  if v_br is null or v_cat = '' then
    return '[]'::jsonb;
  end if;

  -- دورة الجرد للفئة (افتراضي 7 أيام لو الفئة مش متسجّلة)
  select coalesce(s.cycle_days, 7) into v_cycle
    from jard_settings s where s.category = v_cat;
  v_cycle := coalesce(v_cycle, 7);

  -- توحيد جداول الفروع جوّه الدالة (مش view — اقرا التحذير فوق).
  -- لما mig.branch_stock الموحّد ينزل، الـCTE دي بتتبدّل بسطر واحد هنا
  -- وسطر في get_jard_stale.
  with bs as (
    select 'المعمورة'::text as branch, itm_code, itm_name_ar, itm_name_en, sto_qty_big from stock_mamora
    union all
    select 'سان ستيفانو'::text, itm_code, itm_name_ar, itm_name_en, sto_qty_big from stock_san
    union all
    select 'سيدى بشر'::text,    itm_code, itm_name_ar, itm_name_en, sto_qty_big from stock_bishr
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.code), '[]'::jsonb)
    into out_j
    from (
      select distinct on (s.itm_code)
             s.itm_code as code, s.itm_name_ar, s.itm_name_en
        from bs s
       where s.branch = v_br
         and coalesce(nullif(s.sto_qty_big, ''), '0')::numeric > 0
         and (
           case when v_cat = 'fastmove'
                then exists (select 1 from jard_fastmove_codes fc where fc.code = s.itm_code)
                else exists (select 1 from jard_category_flags f
                              where f.itm_code = s.itm_code
                                and f.branch   = v_br
                                and f.category = v_cat)
           end
         )
         -- اتجرد خلال الدورة؟ يبقى مايظهرش تاني
         and not exists (
           select 1 from jard_audit_log l
            where l.code     = s.itm_code
              and l.branch   = v_br
              and l.category = v_cat
              and l.audited_at > now() - make_interval(days => v_cycle)
         )
       order by s.itm_code
    ) t;

  return out_j;
end $fn$;

revoke all on function public.get_jard_items(text, text) from public, anon;
grant execute on function public.get_jard_items(text, text) to authenticated, service_role;


-- ═══ ٢) الأصناف اللي لم تُجرد من مدة ════════════════════════════
-- بديل webhook/jard_stale_report
create or replace function public.get_jard_stale(p_branch text, p_months integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role  text  := coalesce(claims ->> 'role', '');
  v_br     text;
  v_months integer := greatest(coalesce(p_months, 3), 0);
  out_j    jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;

  v_br := public.jard_canon_branch(p_branch);
  if v_br is null then
    return '[]'::jsonb;
  end if;

  -- ⚠️ أول نسخة كانت بتعمل استعلام فرعي **مترابط** (بحث في سجل الجرد
  --    لكل صنف على حدة = عشرات الآلاف من اللمّات) وعملت statement timeout.
  --    الصح: تجميعة واحدة لآخر جرد لكل كود، وبعدين left join — نفس أسلوب
  --    استعلام n8n الأصلي.
  with bs as (
    select 'المعمورة'::text as branch, itm_code, itm_name_ar, itm_name_en, sto_qty_big from stock_mamora
    union all
    select 'سان ستيفانو'::text, itm_code, itm_name_ar, itm_name_en, sto_qty_big from stock_san
    union all
    select 'سيدى بشر'::text,    itm_code, itm_name_ar, itm_name_en, sto_qty_big from stock_bishr
  ),
  audit_last as (
    select l.code, max(l.audited_at) as last_audited
      from jard_audit_log l
     where l.branch = v_br
     group by l.code
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.last_audited nulls first), '[]'::jsonb)
    into out_j
    from (
      select s.itm_code as code, s.itm_name_ar, s.itm_name_en, s.sto_qty_big,
             al.last_audited
        from bs s
        left join audit_last al on al.code = s.itm_code
       where s.branch = v_br
         and coalesce(nullif(s.sto_qty_big, ''), '0')::numeric > 0
         and (al.last_audited is null
              or al.last_audited < now() - make_interval(months => v_months))
    ) t;

  return out_j;
end $fn$;

revoke all on function public.get_jard_stale(text, integer) from public, anon;
grant execute on function public.get_jard_stale(text, integer) to authenticated, service_role;


-- التنضيف: لو النسخة الأولى من الملف ده اتطبّقت، العرض ده لسه موجود
-- وبيوقف مزامنة المخزون. شيله.
drop view if exists public.v_branch_stock;


-- ═══════════════════════════════════════════════════════════════════
-- التحقق (اتعمل على السحابة 2026-09-23) — الأرقام طابقت n8n في 12/12:
--   jard_items   المعمورة: 26/100/567 · سان ستيفانو: 26/110/685 · سيدى بشر: 25/88/535
--                (fastmove / تلاجه / غوالى)
--   jard_stale   4026 · 4348 · 5135
--
-- بعد التطبيق على القاعدتين وتجربة شاشة الجرد:
--   عطّل في n8n: Webhook2 (jard_items) و Webhook5 (jard_stale_report)
--   ⚠️ سيب Webhook (get_balance) شغّال — هو آخر حاجة حيّة في الكانفس ده
--
-- وبعد التطبيق تأكد إن مفيش اعتماد فاضل على جداول المخزون:
--   select count(*) from pg_depend d
--     join pg_class t on t.oid=d.refobjid
--     join pg_class v on v.oid=d.objid and v.relkind in ('v','m')
--     join pg_namespace n on n.oid=t.relnamespace
--    where n.nspname='public'
--      and t.relname in ('stock_mamora','stock_san','stock_bishr');
--   لازم ترجّع 0 — أي رقم غير كده معناه فيه view هيوقف المزامنة.
-- ═══════════════════════════════════════════════════════════════════
