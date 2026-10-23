/* ============================================================
   «لم يُجرد منذ مدة»: تمييز الوارد الجديد
   ------------------------------------------------------------
   المشكلة: التقرير بيقول «رصيده الآن > 0 ومجردش في الفترة». مفيش في
   النظام أي تاريخ لرصيد الصنف، فالصنف اللي كان مصفّر ودخل امبارح
   بيطلع كأنه إهمال — وهو مكانش فيه حاجة تتجرد أصلًا.

   القياس على المعمورة (٩٠ يوم): ١٠٤٢ صنف في القايمة، **٥١٣ منهم
   اتشروا خلال ٣٠ يوم** — يعني نص القايمة تقريبًا وارد حديث.

   المعيار المعتمد (قرار المالك 2026-10-23) — «الرصيد كله من آخر وارد»:
     آخر فاتورة شراء للصنف خلال N يوم (افتراضي ١٤)
     **و** الرصيد الحالي ≤ كمية الفاتورة دي.

   ⚠️ ليه مش «مفيش شراء قبله من ٤ شهور»؟ لأن عمق تاريخ المشتريات مش
   واحد في الفروع: المعمورة وسان سنة، سيدى بشر ٦ شهور، **والسيوف شهر
   بس** — فالمعيار ده كان هيقول إن كل صنف في السيوف «رجع بعد انقطاع».
   معيار «آخر وارد» بيعتمد على آخر فاتورة بس فبيشتغل صح في الأربعة.

   الدالة بترجّع **الحقائق** (last_in, last_qty) والواجهة هي اللي
   بتقرر «جديد ولا لأ» — عشان تغيير عدد الأيام يطبّق فورًا من غير
   نداء جديد للسيرفر.

   ⚠️ والأصناف اللي مالهاش فاتورة عندنا (٣٠٩ في المعمورة) بترجع
   last_in = null وبتفضل ظاهرة — مانقدرش نثبت إنها جديدة، والأسلم
   تفضل في القايمة. وكمان: الوارد بتحويل من فرع تاني مش فاتورة شراء
   فمش هيتعرف.

   الأداء: lateral على آخر فاتورة لكل صنف في القايمة (~١٠٤٢ صنف)
   بيستعمل idx_pii_code — **اتقاس ٢٩٦ مللي ثانية**، فمفيش داعي لجدول
   مُجمَّع (كنت متوقّع إنه هيلزم، والقياس قال غير كده).
   ============================================================ */

create or replace function public.get_jard_stale(p_branch text, p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  claims  jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  pg_role text  := coalesce(claims ->> 'role', '');
  v_br    text;
  v_from  date  := coalesce(p_from, (now() at time zone 'Africa/Cairo')::date - 90);
  v_to    date  := coalesce(p_to,   (now() at time zone 'Africa/Cairo')::date);
  v_union text;
  out_j   jsonb;
begin
  if pg_role <> 'service_role' and coalesce(public.jwt_app_role(), '') = '' then
    return '[]'::jsonb;
  end if;
  v_br := public.jard_canon_branch(p_branch);
  if v_br is null then
    return '[]'::jsonb;
  end if;
  if v_from > v_to then
    select v_to, v_from into v_from, v_to;
  end if;

  /* ⚠️ الكود الإنجليزي للفرع (b.code) لازم يتضاف للـunion: جداول
     المشتريات بتعرف الفرع بالكود، والمخزون بالاسم العربي. */
  select string_agg(
           format('select %L::text as branch, %L::text as bcode, itm_code, itm_name_ar, itm_name_en, sto_qty_big from public.%I',
                  b.name, b.code, 'stock_' || b.code), ' union all ')
    into v_union
    from branches b
   where b.is_active
     and to_regclass('public.' || quote_ident('stock_' || b.code)) is not null;
  if v_union is null then return '[]'::jsonb; end if;

  execute format($q$
    with audit_last as (
      select l.code, max(l.audited_at) as last_audited
        from jard_audit_log l where l.branch = $1 group by l.code
    ),
    audited_in_range as (
      select distinct l.code
        from jard_audit_log l
       where l.branch = $1
         and (l.audited_at at time zone 'Africa/Cairo')::date between $2 and $3
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.last_audited nulls first), '[]'::jsonb)
      from (
        select s.itm_code as code, s.itm_name_ar, s.itm_name_en, s.sto_qty_big,
               al.last_audited,
               lr.last_in, lr.last_qty
          from (%s) s
          left join audit_last al on al.code = s.itm_code
          /* آخر فاتورة شراء فيها الصنف في نفس الفرع */
          left join lateral (
            select h.sec_insert_date as last_in,
                   i.qnty + coalesce(i.bonus, 0) as last_qty
              from purchase_invoice_items i
              join purchase_invoices h
                on h.branch = i.branch and h.pth_id = i.pth_id
             where i.branch = s.bcode and i.itm_code = s.itm_code
             order by h.sec_insert_date desc
             limit 1
          ) lr on true
         where s.branch = $1
           and coalesce(nullif(s.sto_qty_big, ''), '0')::numeric > 0
           and not exists (select 1 from audited_in_range r where r.code = s.itm_code)
      ) t
  $q$, v_union)
  into out_j using v_br, v_from, v_to;

  return out_j;
end $function$;
