-- ═══════════════════════════════════════════════════════════════════
-- مرتجعات التعاقد: كل مرتجع بيومه صف مستقل          (2026-10-09)
--
-- المشكلة (اتكشفت من المالك على مرتجع 1465202):
--   `returns_log.bill_no` هو **رقم الفاتورة الأصلية**، مش رقم المرتجع.
--   والعميل يقدر يرجّع على نفس الفاتورة أكتر من مرة في أيام مختلفة.
--   الدوال كانت بتجمّع بـ(bill_no, branch) فالمرتجعين بيبقوا صف واحد:
--     • القيمة بتتعرض مجموعة  (165 + 100 = 265 بدل 100)
--     • التاريخ المعروض = أحدث مرتجع
--     • ⚠️ والأخطر: **المرتجع الجديد بيرث حالة القديم**. مرتجع 6/10
--       ظهر «مقفول» عشان القفل الجماعي يوم 3/10 كان على مرتجع 17/9
--       اللي على نفس الفاتورة. يعني مرتجع يوصل وما يتعرضش للمراجعة أبدًا.
--   الحالتين المتأثرتين وقت الترحيل: 1465202 (100 ج مخفية) و1470573
--   (154 ج مخفية) — الاتنين المعمورة.
--
-- القرار (المالك 2026-10-09): كل مرتجع بتاريخه صف مستقل.
--
-- ليه **اليوم** مش الطابع الزمني؟
--   بنود المرتجع الواحد بتتسجّل بطوابع متقاربة مش متطابقة (22:30:02 و
--   22:30:20 لنفس المرتجع). التجميع بالطابع كان هيقسّم المرتجع الواحد
--   لصفين. وقياس الفجوات بين الطوابع طلّع تدرّج متصل من ثانية لـ42
--   دقيقة — يعني أي «حد زمني» هيبقى تخمين. فالمفتاح بقى **اليوم**:
--   قاعدة واضحة ومفهومة (مرتجع واحد لكل فاتورة في اليوم)، وبتضم الـ62
--   حالة المتفرقة صح، وبتفصل الـ55 حالة متعددة الأيام صح.
--   النتيجة: 3251 صف بدل 3196.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- ── ١) عمود اليوم على جدول الربط ──────────────────────────────────
alter table public.contract_return_matches
  add column if not exists return_day date;

comment on column public.contract_return_matches.return_day is
  'يوم المرتجع (Africa/Cairo). جزء من مفتاح الربط: الفاتورة + الفرع + اليوم.';

-- ── ٢) الفهرس القديم يتشال الأول عشان التوسيع يقدر يدخّل أيام متعددة ──
drop index if exists public.crm_return_bill_uq;

-- ── ٣) توسيع الربطات الموجودة على أيامها ──────────────────────────
-- الربطة القديمة كانت على الفاتورة كلها، فبتتعلّق بكل الأيام اللي كانت
-- موجودة **وقت الربط**. أي يوم وصل بعد كده يفضل «قيد الانتظار» —
-- وده بالظبط اللي بيطلّع الـ100 والـ154 المخفيين للمراجعة.
with days as (
  select bill_no, branch, return_date::date d
    from public.returns_log group by 1,2,3
), expanded as (
  select m.id,
         d.d,
         row_number() over (partition by m.id order by d.d) rn
    from public.contract_return_matches m
    join days d
      on d.bill_no = m.return_bill_no
     and coalesce(d.branch,'') = coalesce(m.return_branch,'')
     and d.d <= m.matched_at::date
)
-- (أ) الأيام الزيادة: نسخة من الصف الأصلي بيوم مختلف
insert into public.contract_return_matches
  (return_bill_no, return_branch, invoice_id, invoice_bill_no,
   invoice_prev_state, return_value, matched_by, matched_at, status, return_day)
select m.return_bill_no, m.return_branch, m.invoice_id, m.invoice_bill_no,
       m.invoice_prev_state, m.return_value, m.matched_by, m.matched_at,
       m.status, e.d
  from expanded e
  join public.contract_return_matches m on m.id = e.id
 where e.rn > 1;

-- (ب) الصف الأصلي ياخد أول يوم
with days as (
  select bill_no, branch, return_date::date d
    from public.returns_log group by 1,2,3
)
update public.contract_return_matches m
   set return_day = (
         select min(d.d) from days d
          where d.bill_no = m.return_bill_no
            and coalesce(d.branch,'') = coalesce(m.return_branch,'')
            and d.d <= m.matched_at::date)
 where m.return_day is null;

-- ── ٤) حارس: ممنوع نكمّل والصفوف ناقصة يوم ────────────────────────
-- لو ربطة مالهاش ولا يوم مطابق يبقى فيه حاجة مش مفهومة في البيانات،
-- والأسلم إن الترحيل يقع بصوت عالي بدل ما يسيب صفوف بلا مفتاح.
do $$
declare v_n int;
begin
  select count(*) into v_n from public.contract_return_matches where return_day is null;
  if v_n > 0 then
    raise exception 'فيه % ربطة مالهاش يوم مرتجع مطابق — الترحيل اتلغى', v_n;
  end if;
end $$;

alter table public.contract_return_matches alter column return_day set not null;

-- ── ٥) المفتاح الجديد ─────────────────────────────────────────────
create unique index crm_return_bill_day_uq
  on public.contract_return_matches
     (return_bill_no, coalesce(return_branch, ''::text), return_day);


-- ── ٦) دالة العرض ─────────────────────────────────────────────────
drop function if exists public.get_contract_returns(text);

create function public.get_contract_returns(p_branch text default null)
returns table (
  return_bill_no text, return_branch text, return_day date, return_date timestamptz,
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
    select r.bill_no, r.branch, r.return_date::date rday,
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
     group by r.bill_no, r.branch, r.return_date::date
  )
  select rb.bill_no, rb.branch, rb.rday, rb.rdate, rb.ccode, rb.cname,
         round(rb.tval::numeric, 2), rb.icount::int,
         m.invoice_bill_no, m.matched_at, m.matched_by,
         coalesce(m.status, 'قيد الانتظار'),
         rb.on_ci
    from rb
    left join contract_return_matches m
      on m.return_bill_no = rb.bill_no
     and coalesce(m.return_branch,'') = coalesce(rb.branch,'')
     and m.return_day = rb.rday
   order by (m.return_bill_no is not null), rb.rdate desc;
$fn$;

grant execute on function public.get_contract_returns(text) to public, anon, authenticated;


-- ── ٧) دالة الاقتراح ──────────────────────────────────────────────
drop function if exists public.suggest_contract_returns(text, text, timestamptz, numeric, text, integer);

create function public.suggest_contract_returns(
  p_cust_code text, p_cust_name text, p_bill_date timestamptz,
  p_bill_value numeric, p_search text default null, p_limit integer default 50)
returns table (
  return_bill_no text, return_branch text, return_day date, return_date timestamptz,
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
    select r.bill_no, r.branch, r.return_date::date rday,
           max(r.return_date) rdate, max(r.cust_code) ccode, max(r.cust_name) cname,
           sum(r.return_value) tval, count(*) icount,
           exists (select 1 from contract_invoices ci where ci.bill_no = r.bill_no) on_ci
      from returns_log r
     where (
             exists (select 1 from contract_invoices ci where ci.bill_no = r.bill_no)
             or (nullif(btrim(r.cust_code), '') is not null
                 and exists (select 1 from contract_invoices ci2 where ci2.cust_code = r.cust_code))
           )
     group by r.bill_no, r.branch, r.return_date::date
  )
  select rb.bill_no, rb.branch, rb.rday, rb.rdate, rb.ccode, rb.cname,
         round(rb.tval::numeric, 2), rb.icount::int,
         m.invoice_bill_no,
         (p_cust_code is not null and p_cust_code <> '' and rb.ccode = p_cust_code) as same_customer,
         round((abs(extract(epoch from (rb.rdate - p_bill_date)) / 3600.0))::numeric, 1) as hours_diff,
         round((abs(coalesce(rb.tval,0) - coalesce(p_bill_value,0)))::numeric, 2) as val_diff,
         rb.on_ci
    from rb
    left join contract_return_matches m
      on m.return_bill_no = rb.bill_no
     and coalesce(m.return_branch,'') = coalesce(rb.branch,'')
     and m.return_day = rb.rday
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


-- ── ٨) دوال الكتابة ───────────────────────────────────────────────
-- ⚠️ التوقيع القديم **بيتشال** مش بيتساب كـoverload: لو شاشة قديمة
--    لسه بتنادي النسخة بلا يوم، لازم تقع بصوت عالي بدل ما تكتب على
--    مفتاح ناقص وتربط المرتجع الغلط.
drop function if exists public.match_contract_return(text, text, bigint, numeric, text);
drop function if exists public.unmatch_contract_return(text, text);

create function public.match_contract_return(
  p_return_bill_no text, p_return_branch text, p_return_day date,
  p_invoice_id bigint, p_return_value numeric, p_user text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_inv contract_invoices%ROWTYPE; v_old_inv bigint; v_old_prev text; v_prev text;
BEGIN
  IF p_return_day IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'يوم المرتجع مطلوب');
  END IF;

  SELECT * INTO v_inv FROM contract_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'الفاتورة غير موجودة'); END IF;

  SELECT invoice_id, invoice_prev_state INTO v_old_inv, v_old_prev FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no
      AND coalesce(return_branch,'') = coalesce(p_return_branch,'')
      AND return_day = p_return_day;
  IF v_old_inv IS NOT NULL AND v_old_inv <> p_invoice_id THEN
    UPDATE contract_invoices SET bill_state = coalesce(nullif(v_old_prev,''),'فاتورة') WHERE id = v_old_inv;
  END IF;

  v_prev := v_inv.bill_state;
  IF btrim(coalesce(v_prev,'')) = 'مقابل مرتجع' THEN
    SELECT invoice_prev_state INTO v_prev FROM contract_return_matches
     WHERE invoice_id = p_invoice_id
       AND (return_bill_no <> p_return_bill_no
            OR coalesce(return_branch,'') <> coalesce(p_return_branch,'')
            OR return_day <> p_return_day)
       AND coalesce(btrim(invoice_prev_state),'') <> 'مقابل مرتجع'
     ORDER BY matched_at ASC LIMIT 1;
    v_prev := coalesce(nullif(btrim(coalesce(v_prev,'')),''), 'فاتورة');
  END IF;

  INSERT INTO contract_return_matches(return_bill_no, return_branch, return_day,
         invoice_id, invoice_bill_no, invoice_prev_state, return_value, matched_by)
  VALUES (p_return_bill_no, p_return_branch, p_return_day,
          p_invoice_id, v_inv.bill_no, v_prev, p_return_value, p_user)
  ON CONFLICT (return_bill_no, coalesce(return_branch,''), return_day) DO UPDATE
    SET invoice_id = excluded.invoice_id, invoice_bill_no = excluded.invoice_bill_no,
        invoice_prev_state = excluded.invoice_prev_state, return_value = excluded.return_value,
        matched_by = excluded.matched_by, matched_at = now();
  UPDATE contract_invoices SET bill_state = 'مقابل مرتجع' WHERE id = p_invoice_id;
  RETURN jsonb_build_object('success', true, 'invoice_bill_no', v_inv.bill_no);
END $function$;

create function public.unmatch_contract_return(
  p_return_bill_no text, p_return_branch text, p_return_day date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_inv bigint; v_prev text;
BEGIN
  SELECT invoice_id, invoice_prev_state INTO v_inv, v_prev FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no
      AND coalesce(return_branch,'') = coalesce(p_return_branch,'')
      AND return_day = p_return_day;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'مفيش ربط'); END IF;
  IF v_inv IS NOT NULL THEN
    UPDATE contract_invoices SET bill_state = coalesce(nullif(v_prev,''),'فاتورة') WHERE id = v_inv;
  END IF;
  DELETE FROM contract_return_matches
    WHERE return_bill_no = p_return_bill_no
      AND coalesce(return_branch,'') = coalesce(p_return_branch,'')
      AND return_day = p_return_day;
  RETURN jsonb_build_object('success', true);
END $function$;

grant execute on function public.match_contract_return(text, text, date, bigint, numeric, text)
  to public, anon, authenticated;
grant execute on function public.unmatch_contract_return(text, text, date)
  to public, anon, authenticated;

notify pgrst, 'reload schema';

commit;


-- ── الفحص ─────────────────────────────────────────────────────────
select 'صفوف الربط' as البند, count(*)::text as القيمة from public.contract_return_matches
union all
select 'صفوف المرتجعات المعروضة', count(*)::text from public.get_contract_returns('')
union all
select 'رجعت قيد الانتظار بعد الفصل',
       count(*)::text from public.get_contract_returns('')
 where match_status = 'قيد الانتظار' and return_day >= '2026-10-01'
union all
select 'فاتورة 1465202', string_agg(return_day || ' = ' || total_value, '  |  ' order by return_day)
  from public.get_contract_returns('') where return_bill_no = '1465202';
