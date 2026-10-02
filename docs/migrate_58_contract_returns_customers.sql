-- ═══════════════════════════════════════════════════════════════════
-- مرتجعات التعاقد: تشمل مرتجعات عملاء التعاقد كمان
-- ═══════════════════════════════════════════════════════════════════
-- (لازم يتطبّق على **القاعدتين**)
--
-- ═══ اللي اتكشف (2026-10-02) ═══
-- الدالتين كانوا بيفلتروا على شرط واحد:
--     WHERE EXISTS (SELECT 1 FROM contract_invoices ci WHERE ci.bill_no = r.bill_no)
-- يعني: اعرض المرتجع **فقط** لو فاتورته الأصلية فاتورة تعاقد.
--
-- بس النمط الفعلي في الصيدلية مختلف. مثال حقيقي اتفحص:
--   العميل 9801 «محمد سعد رمضان 5410» — عميل تعاقد (5 فواتير):
--     18:12:48  مرتجع على فاتورة 1348931 (نقدي قديمة) ....... 59
--     18:13:36  مرتجع على فاتورة 1364468 (نقدي قديمة) ....... 86
--     18:14:47  **فاتورة تعاقد 1476412** ................... 145
--   59 + 86 = 145 بالظبط. رجّع على فواتير نقدي وأعاد الفوترة على
--   التعاقد بعدها بدقيقتين.
--
-- المرتجعين دول ماكانوش بيظهروا **ولا في التبويب ولا في نافذة الربط**
-- (نفس الفلتر في `suggest_contract_returns`)، يعني المحاسب ماكانش
-- يقدر يربطهم بالفاتورة **حتى يدويًا**. مفيش رسالة ومفيش صفر — بس
-- مش موجودين.
--
-- القياس وقت الإصلاح: 2,878 مرتجع إجمالًا · 628 كانوا بيظهروا ·
--   51 مخفيين رغم إن صاحبهم عميل تعاقد (14,666 ج آخر شهرين).
--
-- ═══ القرار (المالك) ═══
-- التبويب يعرض **مرتجعات التعاقد أو مرتجعات عملاء التعاقد**، ونفس
-- القاعدة في نافذة الربط — عشان مايبقاش فيه تعريفين لـ«مرتجع تعاقد»
-- في نفس الشاشة.
--
-- وعشان الصفين مايتلخبطوش، الدالتين بيرجّعوا عمود `on_contract_bill`
-- والشاشة بتعرضه كشارة (فاتورة تعاقد / عميل تعاقد) + فلتر بالمصدر.
--
-- ⚠️ التوقيع اتغيّر (عمود زيادة) فمحتاج DROP، والصلاحيات اترجّعت.
--
-- التحقق على السحابة: الصفوف القديمة الـ628 بصمتها **مطابقة بالحرف**
--   قبل وبعد (c2ef2dde…)، والإجمالي بقى 679 — الزيادة 51 كلهم
--   `on_contract_bill = false`.
-- ═══════════════════════════════════════════════════════════════════

-- التوسيع بيسأل «هل العميل ده له أي فاتورة تعاقد؟» لكل مرتجع
create index if not exists idx_contract_invoices_cust_code
  on public.contract_invoices (cust_code);

drop function if exists public.get_contract_returns(text);

create function public.get_contract_returns(p_branch text default null)
returns table (
  return_bill_no text, return_branch text, return_date timestamptz,
  cust_code text, cust_name text, total_value numeric, items_count integer,
  matched_invoice_bill_no text, matched_at timestamptz, matched_by text,
  match_status text, on_contract_bill boolean
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with rb as (
    select r.bill_no, r.branch,
           max(r.return_date) rdate, max(r.cust_code) ccode, max(r.cust_name) cname,
           sum(r.return_value) tval, count(*) icount,
           -- بيفرّق الصفين في الشاشة
           exists (select 1 from contract_invoices ci where ci.bill_no = r.bill_no) on_ci
      from returns_log r
     where (
             -- ① مرتجع على فاتورة تعاقد (السلوك الأصلي)
             exists (select 1 from contract_invoices ci where ci.bill_no = r.bill_no)
             -- ② أو مرتجع لعميل عنده تعاقد، حتى لو الفاتورة الأصلية نقدي
             or (nullif(btrim(r.cust_code), '') is not null
                 and exists (select 1 from contract_invoices ci2 where ci2.cust_code = r.cust_code))
           )
       and (p_branch is null or p_branch = '' or r.branch = p_branch)
     group by r.bill_no, r.branch
  )
  select rb.bill_no, rb.branch, rb.rdate, rb.ccode, rb.cname,
         round(rb.tval::numeric, 2), rb.icount::int,
         m.invoice_bill_no, m.matched_at, m.matched_by,
         coalesce(m.status, 'قيد الانتظار'),
         rb.on_ci
    from rb
    left join contract_return_matches m
      on m.return_bill_no = rb.bill_no and coalesce(m.return_branch,'') = coalesce(rb.branch,'')
   order by (m.return_bill_no is not null), rb.rdate desc;
$fn$;

grant execute on function public.get_contract_returns(text) to public, anon, authenticated;


drop function if exists public.suggest_contract_returns(text, text, timestamptz, numeric, text, integer);

create function public.suggest_contract_returns(
  p_cust_code text, p_cust_name text, p_bill_date timestamptz,
  p_bill_value numeric, p_search text default null, p_limit integer default 50)
returns table (
  return_bill_no text, return_branch text, return_date timestamptz,
  cust_code text, cust_name text, total_value numeric, items_count integer,
  matched_invoice_bill_no text, same_customer boolean,
  hours_diff numeric, val_diff numeric, on_contract_bill boolean
)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with rb as (
    select r.bill_no, r.branch,
           max(r.return_date) rdate, max(r.cust_code) ccode, max(r.cust_name) cname,
           sum(r.return_value) tval, count(*) icount,
           exists (select 1 from contract_invoices ci where ci.bill_no = r.bill_no) on_ci
      from returns_log r
     where (
             exists (select 1 from contract_invoices ci where ci.bill_no = r.bill_no)
             or (nullif(btrim(r.cust_code), '') is not null
                 and exists (select 1 from contract_invoices ci2 where ci2.cust_code = r.cust_code))
           )
     group by r.bill_no, r.branch
  )
  select rb.bill_no, rb.branch, rb.rdate, rb.ccode, rb.cname,
         round(rb.tval::numeric, 2), rb.icount::int,
         m.invoice_bill_no,
         (p_cust_code is not null and p_cust_code <> '' and rb.ccode = p_cust_code) as same_customer,
         round((abs(extract(epoch from (rb.rdate - p_bill_date)) / 3600.0))::numeric, 1) as hours_diff,
         round((abs(coalesce(rb.tval,0) - coalesce(p_bill_value,0)))::numeric, 2) as val_diff,
         rb.on_ci
    from rb
    left join contract_return_matches m
      on m.return_bill_no = rb.bill_no and coalesce(m.return_branch,'') = coalesce(rb.branch,'')
   where (p_search is null or p_search = ''
          or rb.bill_no ilike '%' || p_search || '%'
          or coalesce(rb.cname,'') ilike '%' || p_search || '%'
          or coalesce(rb.ccode,'') ilike '%' || p_search || '%')
   order by
     (p_cust_code is not null and p_cust_code <> '' and rb.ccode = p_cust_code) desc,
     abs(extract(epoch from (rb.rdate - p_bill_date))) asc,
     rb.rdate desc
   limit greatest(1, least(p_limit, 100));
$fn$;

grant execute on function public.suggest_contract_returns(text, text, timestamptz, numeric, text, integer)
  to public, anon, authenticated;

notify pgrst, 'reload schema';
