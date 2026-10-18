/* ═══════════════════════════════════════════════════════════════════
   مرتجع المورّد: تاريخ ووقت ومين عمله — من eplus
   ═══════════════════════════════════════════════════════════════════
   ── الخلفية ─────────────────────────────────────────────────────
   المرتجع بيتعمل بطريقتين في eplus:
     ١) مستند مرتجع (Item_back_h/d) — موثّق بالكامل، وإحنا بنسحبه.
     ٢) تعديل سطر الفاتورة (pur_trans_d.itm_back_qty) — وده الغالبية
        (13 مقابل 7 لفارما في المعمورة سبتمبر/أكتوبر؛ فحصت الـ13
        واحدة واحدة ومحدش فيهم ليه مستند).

   وقلت للمالك إن الطريقة التانية مالهاش تاريخ ولا مستخدم. **وده كان
   غلط.** فحص `diag_return_audit.ps1` على eplus طلّع إن `pur_trans_d`
   فيه على مستوى **السطر** نفسه:
       sec_update_date · sec_update_uid · itm_back · itm_back_tax

   إحنا اللي مكناش بنسحبهم — مزامنة البنود بتاخد أعمدة مختارة مش `*`.

   عيّنة حقيقية من eplus وقت الفحص:
     سطر اتسجّل 08:06 بمعرفة محمد عماد، و**اتعدّل 13:53 بمعرفة مستخدم 28**
     وعليه itm_back_qty — ده المرتجع بتاريخه ووقته وصاحبه.

   ── التغيير ─────────────────────────────────────────────────────
   • أعمدة جديدة في `purchase_invoice_items` + اسم المستخدم مترجم من
     جدول `Employee` في eplus (الأرقام: 60=محمد على السيد،
     239=محمد جابر ابو ضيف، 334=محمد عماد).
   • خطوة مزامنة البنود بتسحبهم.
   • `get_supplier_open` بيعرض تاريخ/وقت/صاحب المرتجع بدل تاريخ
     الفاتورة — **مع fallback لتاريخ الفاتورة** للصفوف القديمة اللي
     لسه ماتسحبتش بالأعمدة الجديدة.

   ⚠️ **تحفّظ مكتوب بقصد**: `sec_update_date` = آخر تعديل على السطر،
      مش «وقت مرتجع» بالاسم. لو السطر اتعدّل مرتين (مرتجع ثم تصحيح
      سعر) الوقت بتاع الأخير. مع `itm_back=1` الاستنتاج قوي، بس مش
      مستند. الشاشة بتقول «آخر تعديل» مش «وقت المرتجع».

   ⚠️ المزامنة بتعيد قراءة آخر يومين بس، فالفواتير الأقدم مش هتتعبّى
      لوحدها — محتاجة طلب «سحب فترة» من شاشة المزامنة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) الأعمدة ─────────────────────────────────────────────────── */
alter table public.purchase_invoice_items
  add column if not exists itm_back        integer,
  add column if not exists itm_back_tax    numeric,
  add column if not exists sec_update_date timestamp,
  add column if not exists sec_update_uid  text,
  add column if not exists updated_by      text;

comment on column public.purchase_invoice_items.sec_update_date is
  'آخر تعديل على السطر في eplus — للسطر اللي عليه مرتجع ده عمليًا وقت المرتجع.';
comment on column public.purchase_invoice_items.updated_by is
  'اسم اللي عدّل السطر، مترجم من Employee في eplus.';
comment on column public.purchase_invoice_items.itm_back is
  'علم eplus إن السطر عليه مرتجع.';

create index if not exists purchase_invoice_items_back_idx
  on public.purchase_invoice_items (branch, pth_id)
  where coalesce(itm_back_qty, 0) <> 0;

/* ── 2) خطوة المزامنة تسحبهم ────────────────────────────────────
   الربط باسم المستخدم: sec_update_uid عمود char فيه مسافات زيادة،
   والقيمة ممكن تكون فاضية. الـCASE بيمنع CAST على نص مش رقم —
   SQL Server 2000 بيقع مش بيرجّع null. */
update public.sync_jobs
   set steps = jsonb_set(steps, '{2,select}', to_jsonb(
         'SELECT ''{branch}'' AS branch, d.pth_id, d.ptd_id, d.itm_id, d.qnty, d.bonus,'
      || ' d.itm_pur_price, d.itm_sell, d.itm_cost, d.itm_tax_price, d.itm_dis_mon, d.itm_dis_per,'
      || ' d.exp_date, d.ptd_batch, d.ptd_serial_number, d.itm_back_qty, d.itm_back_pharm,'
      || ' d.itm_back, d.itm_back_tax, d.sec_update_date,'
      || ' LTRIM(RTRIM(d.sec_update_uid)) AS sec_update_uid, eu.e_Name AS updated_by,'
      || ' d.c_id'
      || ' FROM pur_trans_d d'
      || ' JOIN pur_trans_h h ON h.pth_id=d.pth_id'
      || ' LEFT JOIN Employee eu ON eu.e_id ='
      || '   CASE WHEN LTRIM(RTRIM(d.sec_update_uid)) LIKE ''%[^0-9]%'''
      || '          OR LTRIM(RTRIM(d.sec_update_uid)) = '''' THEN NULL'
      || '        ELSE CAST(LTRIM(RTRIM(d.sec_update_uid)) AS decimal(18,0)) END'::text),
         true),
       updated_at = now()
 where id = 'purchases'
   and steps #>> '{2,target}' = 'purchase_invoice_items';

/* ── 3) الشاشة تعرض تاريخ/وقت/صاحب المرتجع ─────────────────────── */
create or replace function public.get_supplier_open(
  p_branch text, p_vendor text, p_from date default null, p_to date default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_out jsonb;
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
    /* بعد الخصم — ده الرقم اللي المورّد بيحاسب بيه وبيظهر في كشفه.
       total_bill لوحده (قبل الخصم) كان بيخلّي كل فاتورة عليها خصم
       تبان مختلفة عن الكشف وهي مطابقة. */
    select h.pth_id, h.ven_bill_no, h.ven_bill_date::date d,
           (h.total_bill - coalesce(h.total_des_mon,0))::numeric total
      from purchase_invoices h
     where h.branch=p_branch and h.ven_name_ar=p_vendor
       and not exists (select 1 from claim_invoices c where c.branch=h.branch and c.pth_id=h.pth_id)
  ),
  ret_bill_open as (
    /* تاريخ المرتجع = آخر تعديل على **السطر** (مش على الفاتورة).
       والـfallback لتاريخ الفاتورة للصفوف اللي اتسحبت قبل
       migrate_149 ولسه مالهاش الأعمدة دي. */
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
       and not exists (select 1 from claim_returns c where c.branch=i.branch and c.ret_kind='bill' and c.r1=i.pth_id and c.r2=i.ptd_id)
  ),
  ret_gen_open as (
    /* المرتجع بمستند — التاريخ والوقت والمستخدم موثّقين أصلًا */
    select r.ibh_id r1, r.ibd_id r2, r.sec_insert_date::date d,
           r.sec_insert_date ts, null::text by_who,
           null::date inv_d, null::text bill_no,
           coalesce(nullif(btrim(r.itm_code),''), r.itm_id::text) code,
           coalesce(nullif(btrim(r.itm_name),''),'—') name,
           r.qty, r.ibd_ven_price price,
           round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2) val
      from purchase_returns r
     where r.branch=p_branch and r.ven_name_ar=p_vendor
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

grant execute on function public.get_supplier_open(text,text,date,date) to anon, authenticated;

notify pgrst, 'reload schema';
