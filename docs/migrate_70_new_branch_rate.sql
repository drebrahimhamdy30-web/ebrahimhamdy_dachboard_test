-- ═══════════════════════════════════════════════════════════════════
--  معدل مشتق للفرع الجديد (الفرع اللي لسه مالوش مبيعات)
-- ═══════════════════════════════════════════════════════════════════
--  الفرع الجديد معدله صفر في كل الأصناف، فمابياخدش أي طلبيات.
--  الحل: ياخد نسبة من معدل فرع تاني مؤقتًا — بإعدادات من الشاشة:
--    • new_branch_rate        : الفرع الجديد ← الفرع المصدر + تفعيل/إغلاق
--    • new_branch_rate_tiers  : شرائح النسبة حسب معدل المصدر
--      (المصدر الضعيف ماياخدش نفس نسبة المصدر القوي)
--
--  ⚠️ بيتطبّق على **الأصناف اللي الفرع الجديد لسه مالوش معدل فيها**
--     (شهور نشطة = 0). أول ما الصنف يتباع فعلًا في الفرع، بياخد
--     معدله الحقيقي ويسيب المشتق — من غير أي تدخل.
--
--  يتطبّق على القاعدتين: السحابة (البرودكشن) والسيرفر الذاتي (التست).
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.new_branch_rate (
  id            bigserial primary key,
  target_branch text        not null unique,
  source_branch text        not null,
  active        boolean     not null default true,
  updated_at    timestamptz not null default now()
);

create table if not exists public.new_branch_rate_tiers (
  id       bigserial primary key,
  rate_min numeric not null,
  percent  numeric not null
);

alter table public.new_branch_rate       enable row level security;
alter table public.new_branch_rate_tiers enable row level security;

drop policy if exists p_all on public.new_branch_rate;
drop policy if exists p_all on public.new_branch_rate_tiers;
create policy p_all on public.new_branch_rate       for all using (true) with check (true);
create policy p_all on public.new_branch_rate_tiers for all using (true) with check (true);

grant select, insert, update, delete on public.new_branch_rate       to authenticated;
grant select, insert, update, delete on public.new_branch_rate_tiers to authenticated;
grant select on public.new_branch_rate       to anon;
grant select on public.new_branch_rate_tiers to anon;
grant usage, select on sequence public.new_branch_rate_id_seq       to authenticated;
grant usage, select on sequence public.new_branch_rate_tiers_id_seq to authenticated;

-- بذرة: السيوف ياخد من سيدى بشر، وسلّم نسب متدرّج
insert into public.new_branch_rate (target_branch, source_branch, active)
select 'السيوف', 'سيدى بشر', true
 where not exists (select 1 from public.new_branch_rate);

insert into public.new_branch_rate_tiers (rate_min, percent)
select * from (values (2::numeric, 10::numeric), (5, 20), (10, 25)) v(a, b)
 where not exists (select 1 from public.new_branch_rate_tiers);

-- ── إعادة بناء دالة المعدلات مع طبقة «المعدل المشتق» ───────────────
create or replace function public.get_consumption_rates()
 returns setof consumption_flat
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  f_base  text := '';
  f_rate  text := '';
  f_pass  text := '';
  f_agg   text := '';
  v_sel   text := '';
  v_out   text := '';
  v_tcode text;
  v_src   text;
  v_sql   text;
  r       record;
  c       record;
begin
  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales'
                  and column_name = r.code) then
      f_base := f_base
        || ', sum(ms.' || quote_ident(r.code) || ') sum_' || r.code
        || ', count(distinct ms.month) filter (where ms.' || quote_ident(r.code) || ' > 0) act_' || r.code;
    else
      f_base := f_base
        || ', 0::numeric sum_' || r.code
        || ', 0::bigint  act_' || r.code;
    end if;

    f_rate := f_rate
      || ', case when b.act_' || r.code || ' > 0'
      || '       then b.sum_' || r.code || '::numeric / b.act_' || r.code
      || '       else 0 end r_' || r.code
      || ', coalesce(b.act_' || r.code || ', 0) act_' || r.code;

    f_pass := f_pass || ', br.r_' || r.code || ', br.act_' || r.code;

    f_agg  := f_agg
      || ', sum(r_' || r.code || ' * qmul) pre_' || r.code
      || ', max(act_' || r.code || ') act_' || r.code;
  end loop;

  for c in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'consumption_flat'
     order by ordinal_position
  loop
    -- الطبقة الداخلية: نفس الحساب القديم، بس كل عمود بإسمه (الطبقة الخارجية محتاجة الأسماء)
    v_sel := v_sel || case
      when c.column_name = 'code'     then ', a.tcode'
      when c.column_name = 'itm_name' then
        ', coalesce(a.name_primary, (select nullif(s.n,'''') from stock_flat s where s.itm_code = a.tcode), a.name_any)'
      when c.column_name = 'refreshed_at' then ', now()'
      when c.column_name like 'av\_%' then
        ', round(a.pre_' || substr(c.column_name, 4) || ' * a.exc * coalesce((select save_factor from demand_tiers t'
        || ' where a.pre_' || substr(c.column_name, 4) || ' >= t.rate_min'
        || '   and a.act_' || substr(c.column_name, 4) || ' >= t.active_min'
        || ' order by t.rate_min desc limit 1), 1), 1)'
      when c.column_name like 'base\_%' then
        ', round(a.pre_' || substr(c.column_name, 6) || ' * a.exc, 1)'
      when c.column_name like 'act\_%' then
        ', a.act_' || substr(c.column_name, 5) || '::int'
      else ', null'
    end || ' ' || quote_ident(c.column_name);

    -- الطبقة الخارجية: المعدل المشتق للفرع الجديد (لو مفعّل والصنف لسه مالوش معدل)
    v_tcode := case when c.column_name like 'av\_%'   then substr(c.column_name, 4)
                    when c.column_name like 'base\_%' then substr(c.column_name, 6) end;
    v_src := null;
    if v_tcode is not null then
      select bs.code into v_src
        from public.new_branch_rate nbr
        join public.branch_letters() bt on bt.name = nbr.target_branch
        join public.branch_letters() bs on bs.name = nbr.source_branch
       where nbr.active and bt.code = v_tcode and bs.code <> v_tcode
       limit 1;
    end if;

    if v_src is null then
      v_out := v_out || ', r.' || quote_ident(c.column_name);
    else
      v_out := v_out
        || ', case when coalesce(r.act_' || v_tcode || ', 0) = 0'
        || '        and coalesce(r.av_' || v_src || ', 0) > 0'
        || '       then round(r.av_' || v_src || ' * coalesce((select t.percent / 100 from public.new_branch_rate_tiers t'
        || '                     where r.av_' || v_src || ' >= t.rate_min order by t.rate_min desc limit 1), 0), 1)'
        || '       else r.' || quote_ident(c.column_name) || ' end ' || quote_ident(c.column_name);
    end if;
  end loop;

  v_sel := ltrim(v_sel, ', ');
  v_out := ltrim(v_out, ', ');

  v_sql :=
       'with base as ('
    || '  select ms.itm_code, max(ms.itm_name) itm_name' || f_base
    || '    from monthly_sales ms group by ms.itm_code'
    || '), base_rate as ('
    || '  select b.itm_code, b.itm_name' || f_rate || ', coalesce(ce.qty,1) exc'
    || '    from base b left join consumption_exceptional ce on ce.itm_code = b.itm_code'
    || '), expanded as ('
    || '  select br.itm_code tcode, br.itm_name' || f_pass || ', br.exc, 1::numeric qmul, true is_primary'
    || '    from base_rate br'
    || '   where not exists (select 1 from code_replace cr where cr.code = br.itm_code)'
    || '  union all'
    || '  select cr.replace, br.itm_name' || f_pass || ', br.exc, cr.qty, false is_primary'
    || '    from base_rate br join code_replace cr on cr.code = br.itm_code'
    || '), agg as ('
    || '  select tcode,'
    || '         max(itm_name) filter (where is_primary) name_primary,'
    || '         max(itm_name) name_any' || f_agg || ', max(exc) exc'
    || '    from expanded group by tcode'
    || '), raw as (select ' || v_sel || ' from agg a'
    || ') select ' || v_out || ' from raw r';

  return query execute v_sql;
end $function$;
