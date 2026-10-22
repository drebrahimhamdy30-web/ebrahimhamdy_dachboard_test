/* ═══════════════════════════════════════════════════════════════════
   خط البداية يبقى **قاعدة بتاريخ** مش لقطة بأرقام فواتير
   ═══════════════════════════════════════════════════════════════════
   ── المشكلة ──────────────────────────────────────────────────────
   خط البداية (مطالبة id=1، is_baseline، to_date = 2026-08-31) اتعمل
   في 11.10.2026 بإدراج **صفوف** في claim_invoices لكل فاتورة كانت
   موجودة لحظتها. فأي فاتورة قديمة تتزامن **بعد** اللحظة دي
   مابيقابلهاش صف، فتبان «مفتوحة» رغم إنها قبل خط البداية.

   وده حصل فعلًا: استلحاق مزامنة في 14–17.10 جاب تاريخ قديم
   (من 17.10.2025 لـ 10.07.2026)، فظهر **مفتوح وهمي**:

     bishr      968 فاتورة ·  2,998,000.69
     mamora   7,614 فاتورة · 28,362,569.99
     san      5,330 فاتورة · 13,314,845.41
     ─────────────────────────────────────────
             13,912 فاتورة · **44.7 مليون** + 3,204 مرتجع · 1.18 مليون

   وده بيخرّب «الصافي المفتوح» وعمود «الفرق» في تبويب مراجعة
   الأرصدة لكل مورّد تقريبًا.

   ── الحل ─────────────────────────────────────────────────────────
   تعريف «المفتوح» يبقى: **مش مقفول في مطالبة** و**تاريخه بعد خط
   البداية**. فأي استلحاق قديم جاي بكرة بيبقى مغطّى تلقائيًا من غير
   أي إدراج صفوف.

   التاريخ بييجي من **صف خط البداية نفسه** (is_baseline) مش من إعداد
   جديد — مصدر واحد للحقيقة، والمالك يغيّره من نفس المكان. دالة
   claim_baseline_cut(branch) بتاخد أقصى to_date من خط بداية الفرع
   أو خط البداية العام (branch='ALL').

   ⚠️ **اتجاه الفشل مقصود:** لو مفيش خط بداية للفرع، الدالة بترجّع
      null و coalesce(..., '-infinity') بيخلّي **ما حدش يتخفي** —
      الشاشة تبان فيها ضوضاء، بس مفيش جنيه بيختفي بالغلط.

   ⚠️ صفوف خط البداية في claim_invoices سايبينها زي ما هي — بقت
      زيادة مش ضرورية بس مش ضارة، وحذفها خطر بلا فايدة.

   ── تغيير تاني في نفس الدالة ────────────────────────────────────
   get_supplier_balance_review_impl كانت لسه بتجمع total_bill
   (**قبل** الخصم) — آخر مكان فاضل على التعريف القديم بعد
   migrate_148 (العرض) و migrate_157 (التقفيل). بقت
   total_bill - total_des_mon زي الاتنين، فعمود «الفرق» بقى بيقارن
   نفس الرقم اللي المورّد بيحاسب بيه.

   ── المرتجع بتاريخ عمله ─────────────────────────────────────────
   مرتجع بيتعمل النهاردة على فاتورة قديمة **لسه مستحق لينا**، فشرط
   خط البداية على المرتجعات بيتحكم بتاريخ المرتجع (sec_update_date /
   sec_insert_date) مش بتاريخ الفاتورة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── ١) تاريخ خط البداية لفرع ───────────────────────────────────── */
create or replace function public.claim_baseline_cut(p_branch text)
returns date language sql stable set search_path to 'public' as $fn$
  select max(c.to_date)
    from supplier_claims c
   where c.is_baseline
     and (c.branch = p_branch or c.branch = 'ALL');
$fn$;
revoke all on function public.claim_baseline_cut(text) from public, anon;

/* ── ٢) المفتوح لمورّد: + شرط التاريخ ──────────────────────────── */
create or replace function public.get_supplier_open_impl(
  p_branch text, p_vendor text, p_from date default null, p_to date default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_out jsonb;
  /* خط البداية: كل اللي قبله مقفول بالقاعدة مش بصف. */
  v_cut date := coalesce(public.claim_baseline_cut(p_branch), '-infinity'::date);
begin
  if p_vendor is null or p_branch is null then
    return jsonb_build_object('error','لازم تختار المورّد والفرع');
  end if;
  with
  bal as (
    select coalesce(max(ven_current_credit),0)
         + coalesce((select adjust from vendor_balance_adjust a where a.branch=p_branch and a.ven_name_ar=p_vendor),0) c
    from purchase_vendors where branch=p_branch and ven_name_ar=p_vendor
  ),
  inv_open as (
    /* بعد الخصم — ده الرقم اللي المورّد بيحاسب بيه (migrate_148). */
    select h.pth_id, h.ven_bill_no, h.ven_bill_date::date d,
           (h.total_bill - coalesce(h.total_des_mon,0))::numeric total
      from purchase_invoices h
     where h.branch=p_branch and h.ven_name_ar=p_vendor
       and h.ven_bill_date::date > v_cut
       and not exists (select 1 from claim_invoices c where c.branch=h.branch and c.pth_id=h.pth_id)
  ),
  ret_bill_open as (
    select i.pth_id r1, i.ptd_id r2,
           coalesce(i.sec_update_date::date, h.ven_bill_date::date) d,
           i.sec_update_date ts, i.updated_by by_who,
           h.ven_bill_date::date inv_d, h.ven_bill_no bill_no,
           coalesce(nullif(btrim(i.itm_code),''), i.itm_id::text) code,
           coalesce(nullif(btrim(i.itm_name),''),'—') name,
           i.itm_back_qty qty, coalesce(i.itm_back_pharm,i.itm_pur_price) price,
           round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2) val
      from purchase_invoice_items i
      join purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
     where i.branch=p_branch and h.ven_name_ar=p_vendor and coalesce(i.itm_back_qty,0)<>0
       and coalesce(i.sec_update_date::date, h.ven_bill_date::date) > v_cut
       and not exists (select 1 from claim_returns c where c.branch=i.branch and c.ret_kind='bill' and c.r1=i.pth_id and c.r2=i.ptd_id)
  ),
  ret_gen_open as (
    select r.ibh_id r1, r.ibd_id r2, r.sec_insert_date::date d,
           r.sec_insert_date ts, null::text by_who,
           null::date inv_d, null::text bill_no,
           coalesce(nullif(btrim(r.itm_code),''), r.itm_id::text) code,
           coalesce(nullif(btrim(r.itm_name),''),'—') name,
           r.qty, r.ibd_ven_price price,
           round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2) val
      from purchase_returns r
     where r.branch=p_branch and r.ven_name_ar=p_vendor
       and r.sec_insert_date::date > v_cut
       and not exists (select 1 from claim_returns c where c.branch=r.branch and c.ret_kind='gen' and c.r1=r.ibh_id and c.r2=r.ibd_id)
  )
  select jsonb_build_object(
    'balance', (select c from bal),
    'open_inv_total', (select coalesce(sum(total),0) from inv_open),
    'open_ret_total', (select coalesce(sum(val),0) from ret_bill_open) + (select coalesce(sum(val),0) from ret_gen_open),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('pth_id',pth_id,'bill_no',ven_bill_no,'date',d,'total',total) order by d desc),'[]'::jsonb)
                   from inv_open where (p_from is null or d>=p_from) and (p_to is null or d<=p_to)),
    'returns', (
      select coalesce(jsonb_agg(x order by (x->>'date') desc),'[]'::jsonb) from (
        select jsonb_build_object('kind','bill','r1',r1,'r2',r2,'date',d,'ts',ts,'by',by_who,'inv_date',inv_d,'bill_no',bill_no,'code',code,'name',name,'qty',qty,'price',price,'val',val) x, d
          from ret_bill_open where (p_from is null or d>=p_from) and (p_to is null or d<=p_to)
        union all
        select jsonb_build_object('kind','gen','r1',r1,'r2',r2,'date',d,'ts',ts,'by',by_who,'inv_date',inv_d,'bill_no',bill_no,'code',code,'name',name,'qty',qty,'price',price,'val',val) x, d
          from ret_gen_open where (p_from is null or d>=p_from) and (p_to is null or d<=p_to)
      ) s)
  ) into v_out;
  return v_out;
end$fn$;

/* ── ٣) مراجعة الأرصدة: + شرط التاريخ + القيمة بعد الخصم ──────── */
create or replace function public.get_supplier_balance_review_impl(
  p_branch text default null, p_min_diff numeric default 5
) returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  with
  /* خط البداية لكل فرع. left join + coalesce تحت عشان فرع مش موجود
     في branches مايتفلترش بالغلط. */
  cuts as (
    select b.code br, public.claim_baseline_cut(b.code) cut
      from branches b
  ),
  inv as (
    /* بعد الخصم (migrate_148/157) — كانت لسه total_bill لوحده. */
    select h.branch, h.ven_name_ar v,
           sum((h.total_bill - coalesce(h.total_des_mon,0))::numeric) inv_total
      from purchase_invoices h
      left join cuts on cuts.br = h.branch
     where (p_branch is null or h.branch = p_branch)
       and h.ven_bill_date::date > coalesce(cuts.cut, '-infinity'::date)
       and not exists (select 1 from claim_invoices c where c.branch=h.branch and c.pth_id=h.pth_id)
     group by h.branch, h.ven_name_ar),
  retb as (
    select i.branch, h.ven_name_ar v,
           sum(round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2)) rt
      from purchase_invoice_items i
      join purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
      left join cuts on cuts.br = i.branch
     where (p_branch is null or i.branch = p_branch) and coalesce(i.itm_back_qty,0)<>0
       and coalesce(i.sec_update_date::date, h.ven_bill_date::date) > coalesce(cuts.cut, '-infinity'::date)
       and not exists (select 1 from claim_returns c where c.branch=i.branch and c.ret_kind='bill' and c.r1=i.pth_id and c.r2=i.ptd_id)
     group by i.branch, h.ven_name_ar),
  retg as (
    select r.branch, r.ven_name_ar v,
           sum(round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2)) rt
      from purchase_returns r
      left join cuts on cuts.br = r.branch
     where (p_branch is null or r.branch = p_branch)
       and r.sec_insert_date::date > coalesce(cuts.cut, '-infinity'::date)
       and not exists (select 1 from claim_returns c where c.branch=r.branch and c.ret_kind='gen' and c.r1=r.ibh_id and c.r2=r.ibd_id)
     group by r.branch, r.ven_name_ar),
  bal as (
    select pv.branch, pv.ven_name_ar v,
           max(pv.ven_current_credit)
         + coalesce((select adjust from vendor_balance_adjust a where a.branch=pv.branch and a.ven_name_ar=pv.ven_name_ar),0) balance
      from purchase_vendors pv
     where (p_branch is null or pv.branch = p_branch)
     group by pv.branch, pv.ven_name_ar),
  allv as (
    select branch,v from inv union select branch,v from retb
    union select branch,v from retg union select branch,v from bal),
  j as (
    select a.branch, a.v vendor,
           round(coalesce(bal.balance,0))::numeric bal_r,
           round(coalesce(inv.inv_total,0))::numeric inv_r,
           round(coalesce(retb.rt,0)+coalesce(retg.rt,0))::numeric ret_r
      from allv a
      left join inv  on inv.branch =a.branch and inv.v =a.v
      left join retb on retb.branch=a.branch and retb.v=a.v
      left join retg on retg.branch=a.branch and retg.v=a.v
      left join bal  on bal.branch =a.branch and bal.v =a.v),
  k as (
    select branch, vendor, bal_r balance, inv_r inv_total, ret_r ret_total,
           (inv_r - ret_r) open_net, (inv_r - ret_r - bal_r) diff
      from j)
  select jsonb_build_object(
    'total_count',    (select count(*) from k where abs(diff) > p_min_diff),
    'total_abs_diff', (select coalesce(sum(abs(diff)),0) from k where abs(diff) > p_min_diff),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by abs(x.diff) desc, x.vendor)
                      from (select branch, vendor, balance, inv_total, ret_total, open_net, diff
                              from k where abs(diff) > p_min_diff) x), '[]'::jsonb));
$fn$;

notify pgrst, 'reload schema';
