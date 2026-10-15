/* ═══════════════════════════════════════════════════════════════════
   المعدل الخام يفضل خام — عشان «شاذ» تبقى معلومة مش ضوضاء
   ═══════════════════════════════════════════════════════════════════
   ── الملاحظة (المالك) ───────────────────────────────────────────
   «لو الصنف معدله 1 يبقى مفيش داعي أصلًا أشوفه شاذ أو لا، لأن كده
   كده هنطلب 1.»

   صح، والقياس أوضح: من 323 سطر معلَّم «شاذ»، **309** الكمية المباعة
   فيهم كانت 1 أصلًا — يعني المعدل كان هيبقى 1 بالقاعدة أو من غيرها.
   **14 بس** هم اللي القاعدة فعلًا نزّلت معدلهم (سولبادين 10 علب،
   مصل انفلوانزا 6، ليراند 3…). يعني 96% من التعليم ضوضاء.

   ── والأسوأ: القيمة الأصلية كانت بتضيع ───────────────────────────
   القاعدة كانت بتتطبّق على av_ **وbase_** (المعدل الخام اللي بيتعرض
   في عمود «المعدل»). فبعد ما تشتغل مافيش أي طريقة تعرف بيها الصنف
   كان معدله كام قبل ما ينزل — الشاشة بتقول «شاذ» ومابتقدرش تقول
   «كان 10».

   عشان أطلّع الـ309/14 فوق اضطريت أرجع لفواتير البيع وأحسبها من الأول.

   ── التغيير ─────────────────────────────────────────────────────
   القاعدة بقت على av_ بس. base_ خام زي اسمه.

   ⚠️ **مابيغيّرش أي رقم طلب**: المطلوب بيتحسب من av_، والفائض من
      sur_ (= av_). base_ عرض وفرز بس.

   والشاشة بقت تعلّم «شاذ» لما القاعدة تكون غيّرت حاجة فعلًا
   (الخام > 1) وبتقول الرقم في الـtooltip.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_consumption_rates()
returns setof public.consumption_flat
language plpgsql
as $fn$
declare
  f_base  text := '';
  f_rate  text := '';
  f_pass  text := '';
  f_agg   text := '';
  f_bill  text := '';   -- تجميعة عدد الفواتير لكل فرع (جوّه CTE الفواتير)
  f_bsel  text := '';   -- قراءة نفس الأعمدة بعد التجميع
  v_sel   text := '';
  v_drv   text := '';
  v_fin   text := '';
  v_join  text := '';
  v_extra text := '';
  v_tcode text;
  v_sd    text;   -- معدل المصدر في طبقة drv   (من الـjoin مباشرة)
  v_sf    text;   -- معدل المصدر في طبقة final (من أعمدة drv)
  v_tier  text;
  v_expr  text;
  v_sql   text;
  r       record;
  o       record;
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

    /* عدد الفواتير لكل صنف في الفرع — الاسم في sales_items اسم بديل */
    f_bill := f_bill
      || ', count(distinct si.bill_no) filter (where si.br = ' || quote_literal(r.code) || ') bills_' || r.code;
    f_bsel := f_bsel || ', b.bills_' || r.code;
  end loop;

  for c in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'consumption_flat'
     order by ordinal_position
  loop
    if c.column_name like 'av\_%' or c.column_name like 'base\_%' then
      v_tcode := case when c.column_name like 'av\_%' then substr(c.column_name, 4)
                      else substr(c.column_name, 6) end;

      if c.column_name like 'av\_%' then
        v_expr := 'round(a.pre_' || v_tcode || ' * a.exc * coalesce((select t.multiply'
          || ' from public.category_rate_tiers t'
          || ' where t.category = a._cat'
          || '   and (t.branch is null or t.branch = ' || quote_literal(coalesce(
               (select bl.name from public.branch_letters() bl where bl.code = v_tcode),
               '')) || ')'
          || '   and a.pre_' || v_tcode || ' >= t.rate_min'
          || '   and a.act_' || v_tcode || ' >= t.active_min'
          || ' order by (t.branch is not null) desc, t.rate_min desc limit 1), 1), 1)';
      else
        v_expr := 'round(a.pre_' || v_tcode || ' * a.exc, 1)';
      end if;

      /* ═══ القاعدة ═══ نشط شهر واحد + فاتورة بيع واحدة = شاذ.
         بتتطبّق على av_ (معدل الشراء) **بس**.

         base_ (المعدل الخام) بيفضل خام بقصد: كانت القاعدة بتنزّله هو
         كمان، فالقيمة الأصلية بتضيع من القاعدة خالص ومايبقاش فيه أي
         طريقة تعرف بيها «نزل من 10» ولا «كان 1 من الأساس». والنتيجة
         إن الشاشة كانت بتعلّم 323 سطر شاذ، 309 منهم معدلهم كان 1
         أصلًا — تعليم مابيقولش حاجة. دلوقتي الفرق باين.

         base_ عرض وفرز بس — المطلوب بيتحسب من av_ والفائض من sur_
         (= av_)، فالتغيير ده مابيمسش أي رقم طلب.

         least عشان مانعليش معدل أصلًا أقل من 1. */
      if c.column_name like 'av\_%' then
        v_sel := v_sel
          || ', case when coalesce(a.act_'   || v_tcode || ', 0) = 1'
          || '        and coalesce(a.bills_' || v_tcode || ', 0) = 1'
          || '       then least(' || v_expr || ', 1)'
          || '       else ' || v_expr || ' end ' || quote_ident(c.column_name);
      else
        v_sel := v_sel || ', ' || v_expr || ' ' || quote_ident(c.column_name);
      end if;
    else
      v_sel := v_sel || case
        when c.column_name = 'code'     then ', a.tcode'
        when c.column_name = 'itm_name' then
          ', coalesce(a.name_primary, (select nullif(s.n,'''') from stock_flat s where s.itm_code = a.tcode), a.name_any)'
        when c.column_name = 'refreshed_at' then ', now()'
        when c.column_name like 'act\_%'   then
          ', a.act_' || substr(c.column_name, 5) || '::int'
        when c.column_name like 'bills\_%' then
          ', a.bills_' || substr(c.column_name, 7) || '::int'
        when c.column_name like 'sur\_%'   then ', null::numeric'
        else ', null'
      end || ' ' || quote_ident(c.column_name);
    end if;
  end loop;

  for r in select * from public.branch_letters() loop
    v_join := v_join
      || ' left join public.branch_calc_settings s_' || r.code
      || '   on s_' || r.code || '.branch = ' || quote_literal(r.name)
      || '  and s_' || r.code || '.category = x._cat'
      || '  and s_' || r.code || '.active';

    v_extra := v_extra
      || ', s_' || r.code || '.source_branch _sb_' || r.code
      || ', s_' || r.code || '.surplus_mode  _sm_' || r.code;
  end loop;

  for c in
    select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'consumption_flat'
     order by ordinal_position
  loop
    v_tcode := case when c.column_name like 'av\_%'  then substr(c.column_name, 4)
                    when c.column_name like 'sur\_%' then substr(c.column_name, 5) end;

    v_sd := null; v_sf := null;
    if v_tcode is not null then
      /* في drv الإعداد جاي من الـjoin؛ وفي final من أعمدة drv */
      v_sd := 'case s_' || v_tcode || '.source_branch';
      v_sf := 'case d._sb_' || v_tcode;
      for o in select * from public.branch_letters() where code <> v_tcode loop
        v_sd := v_sd || ' when ' || quote_literal(o.name) || ' then x.av_' || o.code;
        v_sf := v_sf || ' when ' || quote_literal(o.name) || ' then d.av_' || o.code;
      end loop;
      v_sd := v_sd || ' else null end';
      v_sf := v_sf || ' else null end';
    end if;

    if c.column_name like 'av\_%' then
      v_tier := 'coalesce((select t.percent / 100 from public.new_branch_rate_tiers t'
             || ' where (' || v_sd || ') >= t.rate_min order by t.rate_min desc limit 1), 0)';
      v_drv := v_drv
        || ', case when s_' || v_tcode || '.rate_source = ''derived'''
        || '        and coalesce(x.act_' || v_tcode || ', 0) = 0'
        || '        and coalesce(' || v_sd || ', 0) > 0'
        || '       then round(coalesce(' || v_sd || ', 0) * ' || v_tier || ', 1)'
        || '       else x.' || quote_ident(c.column_name) || ' end ' || quote_ident(c.column_name);
    else
      v_drv := v_drv || ', x.' || quote_ident(c.column_name);
    end if;

    if c.column_name like 'sur\_%' then
      v_fin := v_fin
        || ', case when d._sm_' || v_tcode || ' = ''source_full'''
        || '        and coalesce(d.act_' || v_tcode || ', 0) = 0'
        || '        and coalesce(' || v_sf || ', 0) > 0'
        || '       then ' || v_sf
        || '       else d.av_' || v_tcode || ' end ' || quote_ident(c.column_name);
    else
      v_fin := v_fin || ', d.' || quote_ident(c.column_name);
    end if;
  end loop;

  v_sel := ltrim(v_sel, ', ');
  v_drv := ltrim(v_drv, ', ');
  v_fin := ltrim(v_fin, ', ');

  v_sql :=
       'with amap as ('
    || '  select bl.code, unnest(b.aliases) alias'
    || '    from public.branch_letters() bl'
    || '    join public.branches b on b.name = bl.name'
    || '), bills as ('
    || '  select si.itm_code' || f_bill
    || '    from (select s.itm_code, s.bill_no, m.code br'
    || '            from sales_items s join amap m on m.alias = s.store_name'
    || '           where s.itm_qty > 0) si'
    || '   group by si.itm_code'
    || '), base as ('
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
    || '), catted as ('
    || '  select a.*, coalesce((select public.item_category(s.co, s.med) from stock_flat s'
    || '                         where s.itm_code = a.tcode limit 1), ''cos'') _cat'
    || '    from agg a'
    || '), withbills as ('
    || '  select c.*' || f_bsel || ' from catted c'
    || '  left join bills b on b.itm_code = c.tcode'
    || '), raw as (select ' || v_sel || ', a._cat from withbills a'
    || '), drv as (select ' || v_drv || ', x._cat' || v_extra
    || '             from raw x' || v_join
    || '), final as (select ' || v_fin || ' from drv d'
    || ') select * from final';

  return query execute v_sql;
end
$fn$;
/* إعادة الحساب فورًا — غير كده الأعمدة تفضل بالقيم المقصوصة */
select public.refresh_consumption_rates();
select public.refresh_purchase_orders(true);
