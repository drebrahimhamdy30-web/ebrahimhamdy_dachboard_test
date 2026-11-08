/* ═══════════════════════════════════════════════════════════════════
   الموقف اليومي: تاريخ اللقطات + مبيعات الشهر بالفرع (لأجل الفلاتر)
   ═══════════════════════════════════════════════════════════════════
   الشاشة اتزاد فيها شريط فلاتر: الفرع، المقارنة مع، والعرض.

   ── ليه الدالة بترجّع التاريخ كله مش لقطة واحدة ───────────────────
   قاعدة الفلاتر عندنا: **تطبّق فورًا بمجرد التغيير** من غير زر. لو
   «المقارنة مع» كانت بتعمل نداء جديد للسيرفر كل مرة، التغيير كان
   هيبقى فيه انتظار. والبيانات صغيرة (٦٠ يوم × ٤ فروع × ٧ أرقام)
   فبترجع كلها مرة واحدة والمقارنة بتحصل في المتصفح لحظيًا.

   وخيارات المقارنة بتتبني من **اللقطات الموجودة فعلًا** مش من قائمة
   ثابتة «أمس / أسبوع / شهر» — لو لقطة فاتت، الخيار الثابت كان هيوعد
   بمقارنة مش موجودة ويطلع فرق غلط.

   ── مبيعات الشهر بالفرع ──────────────────────────────────────────
   قبل كده كان فيه رقم واحد للسلسلة، فلما تفلتر على فرع كانت الكروت
   بتختفي. دلوقتي كل فرع معاه مبيعاته وربحه وهامشه، والواجهة بتجمعهم
   حسب الفلتر.

   ⚠️ الحساب اتحط في دالة منفصلة (`owner_mtd_branch`) عشان الحارس
      على الجدول الناقص يفضل `IF` منفصل — بوستجرس بيخطط الاستعلام
      كله فبيقع على جدول مش موجود حتى لو الشرط مكانش هيوصله،
      و`eplus_monthly_pnl` موجود على السحابة بس.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.owner_mtd_branch(p_branch text, p_ym text)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v jsonb;
begin
  if to_regclass('public.eplus_monthly_pnl') is null then return null; end if;
  select jsonb_build_object(
           'sales',  round(sum(aft)),
           'profit', round(sum(aft - cost)),
           'margin', round(100.0 * sum(aft - cost) / nullif(sum(aft),0), 1))
    into v
    from eplus_monthly_pnl
   where basis = 'c' and ym = p_ym and branch = p_branch;
  return v;
end$fn$;

revoke all on function public.owner_mtd_branch(text,text) from public, anon, authenticated;

create or replace function public.get_owner_position()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_role text := public.jwt_app_role();
  r       record;
  tbl     text;
  v_rows  jsonb := '[]'::jsonb;
  v_sell  numeric; v_cost numeric; v_cov numeric; v_upd timestamptz;
  v_cash  numeric; v_cust numeric; v_vend numeric;
  v_hist  jsonb; v_mtd jsonb; v_fresh jsonb;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_ym    text := to_char((now() at time zone 'Africa/Cairo')::date, 'YYYY-MM');
begin
  if v_role is null then
    raise exception 'غير مصرّح: يلزم تسجيل الدخول' using errcode = '42501';
  end if;
  if v_role <> 'admin' and not exists (
       select 1 from page_permissions pp
        where pp.role = v_role and pp.page_key = 'owner_position' and pp.can_view) then
    raise exception 'غير مصرّح: الشاشة دي للمالك' using errcode = '42501';
  end if;

  for r in
    select code, name from branches
     where is_active and coalesce(code,'') <> ''
     order by sort_order nulls last, name
  loop
    tbl := 'stock_' || r.code;
    v_sell := 0; v_cost := 0; v_cov := null; v_upd := null;

    if to_regclass('public.' || quote_ident(tbl)) is not null then
      execute format($q$
        with lc_br as (
          select distinct on (itm_code) itm_code, itm_pur_price c
            from purchase_invoice_items
           where branch = %L and itm_pur_price > 0 and coalesce(btrim(itm_code),'') <> ''
           order by itm_code, pth_id desc, ptd_id desc),
        lc_any as (
          select distinct on (itm_code) itm_code, itm_pur_price c
            from purchase_invoice_items
           where itm_pur_price > 0 and coalesce(btrim(itm_code),'') <> ''
           order by itm_code, pth_id desc, ptd_id desc),
        s as (
          select itm_code,
                 coalesce(nullif(btrim(sto_qty_big::text),'')::numeric,0)        q,
                 coalesce(nullif(btrim(itm_sell_price_big::text),'')::numeric,0) p,
                 updated_at
            from public.%I)
        select
          coalesce(sum(s.q * s.p), 0),
          coalesce(sum(s.q * coalesce(lc_br.c, lc_any.c, 0)), 0),
          round(100.0 * coalesce(sum(case when coalesce(lc_br.c, lc_any.c) is not null
                                          then s.q * s.p else 0 end), 0)
                      / nullif(sum(s.q * s.p), 0), 1),
          max(s.updated_at)
          from s
          left join lc_br  on lc_br.itm_code  = s.itm_code
          left join lc_any on lc_any.itm_code = s.itm_code
      $q$, r.code, tbl)
      into v_sell, v_cost, v_cov, v_upd;

      if coalesce(v_cov,0) > 0 and v_cov < 100 and v_sell > 0 then
        v_cost := round(v_cost * 100.0 / v_cov, 2);
      end if;
    end if;

    select coalesce(sum(coalesce(v.ven_current_credit,0) + coalesce(a.adjust,0)), 0)
      into v_vend
      from purchase_vendors v
      left join vendor_balance_adjust a
             on a.branch = v.branch and a.ven_name_ar = v.ven_name_ar
     where v.branch = r.code;

    select coalesce(sum(greatest(balance,0)), 0) into v_cust
      from (
        select case r.code
                 when 'mamora' then coalesce(nullif(btrim(c.balance),'')::numeric,0)
                 when 'san'    then coalesce(nullif(btrim(c.balance_san),'')::numeric,0)
                 when 'bishr'  then coalesce(nullif(btrim(c.balance_bishr),'')::numeric,0)
                 when 'seyouf' then coalesce(nullif(btrim(c.balance_seyouf),'')::numeric,0)
                 else 0 end as balance
          from customers c) t;

    v_cash := 0;
    if to_regclass('public.eplus_safes') is not null then
      select coalesce(sum(balance), 0) into v_cash
        from eplus_safes where branch = r.code and coalesce(active,0) = 1;
    end if;

    v_rows := v_rows || jsonb_build_object(
      'code', r.code, 'name', r.name,
      'stock_cost', round(coalesce(v_cost,0)),
      'stock_sell', round(coalesce(v_sell,0)),
      'cost_coverage_pct', v_cov,
      'cash', round(coalesce(v_cash,0)),
      'customers_debt', round(coalesce(v_cust,0)),
      'vendors_due', round(coalesce(v_vend,0)),
      'net', round(coalesce(v_cost,0) + coalesce(v_cash,0)
                 + coalesce(v_cust,0) - coalesce(v_vend,0)),
      'mtd', public.owner_mtd_branch(r.code, v_ym),
      'stock_updated_at', v_upd);
  end loop;

  /* آخر ٦٠ لقطة قبل النهارده — الواجهة بتقارن بأي واحدة فيهم فورًا */
  select coalesce(jsonb_agg(jsonb_build_object('d', t.d, 'rows', t.rows) order by t.d desc), '[]'::jsonb)
    into v_hist
    from (
      select d, jsonb_object_agg(branch, to_jsonb(p) - 'd' - 'captured_at' - 'branch') rows
        from daily_position p
       where d < v_today and d >= v_today - 60
       group by d) t;

  if to_regclass('public.eplus_monthly_pnl') is not null then
  select jsonb_build_object(
           'ym', ym, 'sales', round(sum(aft)),
           'profit', round(sum(aft - cost)),
           'margin', round(100.0 * sum(aft - cost) / nullif(sum(aft),0), 1))
    into v_mtd
    from eplus_monthly_pnl
   where basis = 'c' and ym = v_ym
   group by ym;
  end if;

  v_fresh := jsonb_build_object(
    'customers', (select max(updated_at) from customers),
    'vendors',   (select max(synced_at)  from purchase_vendors),
    'pnl', null, 'cash', null);
  if to_regclass('public.eplus_monthly_pnl') is not null then
    select jsonb_set(v_fresh, '{pnl}', to_jsonb(max(synced_at))) into v_fresh from eplus_monthly_pnl;
  end if;
  if to_regclass('public.eplus_safes') is not null then
    select jsonb_set(v_fresh, '{cash}', to_jsonb(max(synced_at))) into v_fresh from eplus_safes;
  end if;

  return jsonb_build_object(
    'as_of', now(), 'today', v_today, 'ym', v_ym, 'branches', v_rows,
    'history', v_hist, 'mtd', coalesce(v_mtd, '{}'::jsonb), 'freshness', v_fresh);
end$fn$;

revoke all on function public.get_owner_position() from public, anon;
grant execute on function public.get_owner_position() to authenticated;

notify pgrst, 'reload schema';
