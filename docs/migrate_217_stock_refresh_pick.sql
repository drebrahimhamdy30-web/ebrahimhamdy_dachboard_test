-- ═══════════════════════════════════════════════════════════════════
--  المزامنة الفرقية: جدول المخزون نفسه هو الطابور
-- ═══════════════════════════════════════════════════════════════════
--  حادثة 2026-11-15: عقدة «رصيد» فشلت في صنف واحد → الجولة كلها وقعت →
--  مفيش كتابة → `stock_sync_window` (المربوطة بآخر كتابة) ماتحرّكتش →
--  كل جولة أكبر من اللي قبلها لحد ما الجولات دخلت في بعض وخنقت eplus
--  المعمورة (~78 ألف طلب في يوم ونص).
--
--  الحل من غير طابور منفصل: eplus بيقول «الصنف اتحرّك إمتى»
--  (`last_trans_date` للكمية، `update_date` للسعر/الاسم)، وجدول
--  `stock_<فرع>` عندنا فيه نفس التاريخين من آخر كتابة. فالصنف محتاج
--  تحديث لو تاريخه في eplus **أحدث** من المحفوظ. الصنف اللي فشل بحثه
--  بيفضل تاريخه القديم → بيفضل «محتاج تحديث» → بيتعاد لوحده في الجولة
--  اللي بعدها، طول ما هو جوّه النافذة (الوركفلو بيسأل عن آخر 3 ساعات).
--
--  ⚠️ بنقارن صفوف مخازن الفرع بس (`branches.aliases`): رد الـAPI بيرجّع
--     مخازن الفروع التانية كمان، وكانت بتتبحث على الفاضي (قيس 11:36:
--     2 من 11 صنف كانوا اتحرّكوا في مخزن فرع تاني بس).
--  ⚠️ التواريخ نص بصيغة eplus `M/D/YYYY h:mm:ss AM` من نفس الـAPI في
--     الطرفين، فالمقارنة بعد التحويل متسقة. النص اللي مش بالصيغة دي
--     بيتعامل كـnull (مايوقعش الدالة).
--  ⚠️ `p_limit` = سقف الجولة: الباقي بيفضل «محتاج تحديث» وبيتاخد في
--     الجولة الجاية — الأقدم الأول عشان ماحدش يتأجّل للأبد.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.eplus_ts(p text)
returns timestamp
language sql
stable
as $$
  select case when p ~ '^\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M$'
              then to_timestamp(p, 'MM/DD/YYYY HH12:MI:SS AM')::timestamp
         end
$$;

create or replace function public.stock_refresh_pick(
  p_branch text,
  p_rows   jsonb,
  p_limit  integer default 60
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_tbl    text;
  v_stores text[];
  v_out    jsonb;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows لازم تكون مصفوفة JSON';
  end if;

  select 'stock_' || bl.code, b.aliases
    into v_tbl, v_stores
    from public.branch_letters() bl
    join public.branches b on b.name = bl.name
   where bl.code = p_branch;
  if v_tbl is null or to_regclass('public.' || v_tbl) is null then
    raise exception 'فرع غير معروف أو جدول مخزون مش موجود: %', p_branch;
  end if;
  if v_stores is null or array_length(v_stores, 1) is null then
    raise exception 'الفرع % مالوش أسماء مخازن (branches.aliases)', p_branch;
  end if;

  execute format($q$
    with e as (                       -- تغييرات eplus لمخازن الفرع، صف لكل كود
      select btrim(x.itm_code)                        as code,
             max(nullif(btrim(x.itm_name_ar), ''))    as name,
             max(public.eplus_ts(x.last_trans_date))  as e_trans,
             max(public.eplus_ts(x.update_date))      as e_upd
        from jsonb_to_recordset($1) as x(itm_code text, itm_name_ar text, sto_name text,
                                         last_trans_date text, update_date text)
       where x.sto_name = any($2) and coalesce(btrim(x.itm_code), '') <> ''
       group by btrim(x.itm_code)
    ), d as (
      select e.code,
             coalesce(e.name, nullif(btrim(s.itm_name_ar), '')) as name,
             e.e_trans, e.e_upd,
             public.eplus_ts(s.last_trans_date) as s_trans,
             public.eplus_ts(s.update_date)     as s_upd,
             s.itm_code is null                 as is_new
        from e left join public.%I s on s.itm_code = e.code
    ), n as (
      select *, case when is_new then 'new'
                     when e_trans > coalesce(s_trans, '-infinity') then 'qty'
                     else 'item' end as reason
        from d
       where is_new
          or e_trans > coalesce(s_trans, '-infinity')
          or e_upd   > coalesce(s_upd,   '-infinity')
    )
    select jsonb_build_object(
      'candidates', (select count(*) from e),
      'need',       (select count(*) from n),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'reason', reason)
                         order by ord nulls first)
          from (select *, greatest(e_trans, e_upd) as ord
                  from n order by greatest(e_trans, e_upd) nulls first
                 limit $3) p), '[]'::jsonb))
  $q$, v_tbl)
  into v_out
  using p_rows, v_stores, greatest(coalesce(p_limit, 60), 1);

  return v_out || jsonb_build_object('branch', p_branch, 'stores', to_jsonb(v_stores),
                                     'limit', p_limit, 'at', now());
end $$;

revoke all on function public.stock_refresh_pick(text, jsonb, integer) from public, anon, authenticated;
grant execute on function public.stock_refresh_pick(text, jsonb, integer) to service_role;
