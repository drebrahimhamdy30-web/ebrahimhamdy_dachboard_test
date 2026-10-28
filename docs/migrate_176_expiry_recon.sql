/* ═══════════════════════════════════════════════════════════════════
   لوحة Nearly Expire — نسخة مبسّطة: المشترى مقابل المُصفَّر
   ═══════════════════════════════════════════════════════════════════
   طلب المالك: بدل كل البطاقات والرسومات، أربعة أرقام بس —
   قيمة المنتهى على مدار الشهور · قيمة ما تم تصفيره · الفرق (المباع) ·
   وأسباب تسوية الأرصدة على مدار الشهور بالقيمة فقط.

   ── «قيمة المنتهى» جت منين ───────────────────────────────────────
   أول فكرة كانت: الرصيد وقت الانتهاء من لقطات `item_expiry`. وده
   **مش متاح بأثر رجعي** — اللقطات بدأت تتحفظ ٢٧/١٠/٢٠٢٦ بعد
   `migrate_165`، وقبلها الجدول كان بيتمسح يوميًا. يعني أول رقم كان
   هيطلع بعد شهر.

   المصدر اللي حلّها: **بنود فواتير الشراء فيها تاريخ صلاحية كل بند**
   (`purchase_invoice_items.exp_date`). فـ«قيمة المنتهى» بقت **قيمة
   اللي اشتريناه بتاريخ صلاحية الشهر ده**، والفرق بينها وبين المُصفَّر
   هو اللي اتصرف قبل الانتهاء — بيعًا أو إرجاعًا للمورّد أو تحويلًا.
   ده شغّال بأثر رجعي، ومعناه أوضح للمالك: «من اللي اشتريته، ضاع كام؟».

   ── حدّان مكتوبان في الشاشة ──────────────────────────────────────
   ١. **الأشهر الناقصة**: أقدم فاتورة شراء عندنا ٤/٢٠٢٥، فالدفعة اللي
      انتهت قبل ٥/٢٠٢٦ اتشرت غالبًا قبل ما نسجّل. الحدّ محسوب من
      البيانات نفسها (`أول فاتورة + 13 شهر`) مش رقم مكتوب باليد،
      عشان يتزحزح لوحده كل ما تدخل فواتير أقدم.
   ٢. **الشهور الجاية اتشالت خالص**. كانت بتعرض «المشترى بهذه
      الصلاحية» لشهر لسه ماجاش — رقم ضخم (٢.١ مليون لأكتوبر ٢٠٢٧)
      أغلبه اتباع من زمان، فلا هو معرّض ولا فاقد. المعرّض القادم
      مكانه تبويب «القائمة» لأنه بيتعمل عليه فعل مش بيتقاس.

   ⚠️ **الشهر منسوب لتاريخ انتهاء الدفعة** في العمودين — مش لتاريخ
      الشراء ولا لتاريخ التصفير. من غير كده الطرح مالوش معنى:
      التصفير بيتعمل على دفعات لما حد ينضّف، فبيتكوّم في شهر واحد.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_expiry_recon(
  p_branch  text default null,
  p_company text default null,
  p_from    text default null,   -- 'YYYY-MM'
  p_to      text default null    -- 'YYYY-MM'
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_scope text := public.purchase_branch_scope(p_branch, 'expiry');
  v_cur   date := date_trunc('month', current_date)::date;
  v_to    date;
  v_from  date;
  v_thin  date;
  v_out   jsonb;
begin
  v_to := case when p_to ~ '^\d{4}-\d{2}$' then (p_to || '-01')::date else v_cur end;
  /* الشهر الجاري أقصى حد — الشهر اللي لسه ماجاش مالوش معنى هنا */
  if v_to > v_cur then v_to := v_cur; end if;
  v_from := case when p_from ~ '^\d{4}-\d{2}$' then (p_from || '-01')::date
                 else (v_to - interval '11 months')::date end;
  if v_from > v_to then v_from := v_to; end if;
  /* حد الثقة: محسوب من أقدم فاتورة، مش رقم ثابت */
  select date_trunc('month', min(ven_bill_date))::date + interval '13 months'
    into v_thin from purchase_invoices;
  v_thin := coalesce(v_thin, v_from);

  with
  months as (
    select generate_series(v_from, v_to, interval '1 month')::date d
  ),
  /* ── المشترى، منسوبًا لشهر صلاحية البند ── */
  buy as (
    select date_trunc('month', p.exp_date)::date d,
           sum(coalesce(p.line_total, p.qnty * p.itm_pur_price)) v
      from purchase_invoice_items p
      left join stock_flat sf on sf.itm_code = p.itm_code
     where p.exp_date >= v_from and p.exp_date < v_to + interval '1 month'
       and (v_scope is null or p.branch = v_scope)
       and (p_company is null or sf.co = p_company)
     group by 1
  ),
  /* ── المُصفَّر بسبب الانتهاء، منسوبًا لشهر الصلاحية برضه ── */
  adj as (
    select a.*,
           /* الكود الخام أولًا والجسر آخر حل — راجع [[eplus-itmid-code-bridge]] */
           case when s0.itm_code is not null then a.itm_code
                else coalesce(m.itm_code, a.itm_code) end code
      from stock_adjustments a
      left join stock_flat s0   on s0.itm_code = a.itm_code
      left join eplus_id_code m on m.itm_id::text = a.itm_code
     where (v_scope is null or a.branch = v_scope)
  ),
  zer as (
    select date_trunc('month', a.exp_date)::date d, sum(a.cost_value) v, count(*) n
      from adj a left join stock_flat sf on sf.itm_code = a.code
     where a.cause_id = 2 and a.diff > 0 and a.exp_date is not null
       and a.exp_date >= v_from and a.exp_date < v_to + interval '1 month'
       and (p_company is null or sf.co = p_company)
     group by 1
  ),
  rows as (
    select to_char(m.d,'YYYY-MM') m,
           round(coalesce(b.v, 0)) bought,
           round(coalesce(z.v, 0)) zeroed,
           coalesce(z.n, 0) zrows,
           (m.d < v_thin) thin,
           (m.d = v_cur)  running
      from months m
      left join buy b on b.d = m.d
      left join zer z on z.d = m.d
  ),
  /* ── أسباب التسوية، منسوبة لشهر تنفيذ التسوية ── */
  cz as (
    select date_trunc('month', a.changed_at)::date d,
           coalesce(a.cause, '(بدون سبب)') cause,
           round(coalesce(sum(a.cost_value) filter (where a.diff > 0), 0)) outv,
           round(coalesce(-sum(a.cost_value) filter (where a.diff < 0), 0)) inv
      from adj a left join stock_flat sf on sf.itm_code = a.code
     where a.changed_at >= v_from and a.changed_at < v_to + interval '1 month'
       and (p_company is null or sf.co = p_company)
     group by 1, 2
  ),
  /* أعلى ٦ أسباب بالخروج، والباقي «أخرى» — عشان الجدول مايتمددش */
  top6 as (
    select cause from cz group by cause order by sum(outv) desc nulls last limit 6
  ),
  cz2 as (
    select d, case when cause in (select cause from top6) then cause else 'أخرى' end cause,
           sum(outv) outv, sum(inv) inv
      from cz group by 1, 2
  )
  select jsonb_build_object(
    'scope', v_scope,
    'from',  to_char(v_from,'YYYY-MM'),
    'to',    to_char(v_to,'YYYY-MM'),
    'thin_until', to_char(v_thin,'YYYY-MM'),
    'months', coalesce((select jsonb_agg(jsonb_build_object(
                  'm', m, 'bought', bought, 'zeroed', zeroed, 'rows', zrows,
                  'thin', thin, 'running', running,
                  /* الفرق والنسبة للأشهر الصالحة فقط */
                  'diff', case when thin then null else greatest(0, bought - zeroed) end,
                  'loss', case when thin or bought <= 0 then null
                               else round(zeroed * 100.0 / bought, 1) end)
                  order by m) from rows), '[]'::jsonb),
    'cause_cols', coalesce((select jsonb_agg(c order by o desc nulls last)
                    from (select cause c, sum(outv) o from cz2 group by cause) q), '[]'::jsonb),
    'cause_rows', coalesce((select jsonb_agg(x order by x->>'m')
       from (select jsonb_build_object(
               'm', to_char(d,'YYYY-MM'),
               'v', (select jsonb_object_agg(cause, outv) from cz2 z2 where z2.d = z.d),
               'out', sum(outv), 'in', sum(inv)) x
             from cz2 z group by d) q), '[]'::jsonb),
    'totals', (select jsonb_build_object(
                 'bought', coalesce(sum(bought) filter (where not thin), 0),
                 'zeroed', coalesce(sum(zeroed) filter (where not thin), 0),
                 'diff',   coalesce(sum(greatest(0, bought - zeroed)) filter (where not thin), 0),
                 'months', count(*) filter (where not thin),
                 'loss',   case when coalesce(sum(bought) filter (where not thin), 0) > 0
                                then round(sum(zeroed) filter (where not thin) * 100.0
                                         / sum(bought) filter (where not thin), 1)
                                else null end)
               from rows)
  ) into v_out;

  return v_out;
end$fn$;

revoke all on function public.get_expiry_recon(text,text,text,text) from public, anon;
grant execute on function public.get_expiry_recon(text,text,text,text) to authenticated;

/* فهرس على شهر الصلاحية — العمودان بيتجمّعوا عليه */
create index if not exists pii_exp_date_idx on public.purchase_invoice_items (exp_date);
create index if not exists stock_adj_exp_idx on public.stock_adjustments (exp_date)
  where cause_id = 2;

notify pgrst, 'reload schema';
