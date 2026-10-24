/* ============================================================
   «الفرق عند كل تقفيلة» — تاريخ المطابقة شيفت بشيفت
   ------------------------------------------------------------
   التبويب الحالي بيدّي **الوضع دلوقتي** بس. المطلوب (قرار المالك
   2026-10-24): عند كل إغلاق وردية نعرف رصيد خزنة visa ومجموع المصادر
   ساعتها — فأي تحرّك في الفرق نعرف **في أي شيفت** حصل ومين كان فيه.

   🔑 **وليه التقفيلة بالذات هي نقطة القياس الصح:** في اللحظة دي الموظف
   بيكتب أرصدة المحافظ بنفسه، فالجانبان **متقاسين في نفس الدقيقة**.
   التبويب الحالي بيقارن رصيد خزنة لحظي مع أرقام محافظ عمرها ساعات،
   والفرق الناتج عن الفارق الزمني ده مش فرق حقيقي.

   كل مكوّن بيتعاد بناؤه لأي لحظة ماضية من طابع زمني موجود:
     • خزنة visa = الرصيد الحالي ناقص حركات الخزنة بعد اللحظة
       (cashier_transactions على F_Cash_Store بتاع visa).
       ✔ اتأكد: أعدنا بناء رصيد المعمورة يوم ٢١/١٠ ١٣:٤٦ فطلع
         ٥٢٨٬٤٩٠٫٧٢٢ = المحفوظ **بفرق صفر**.
     • المحافظ  = closing_balance بتاع نفس الوردية.
     • باي موب  = اللي لسه ماوصلش البنك وقتها (bank_settled_at).
     • انستاباي = المعلن في الورديات ناقص المرحّل لحد اللحظة (posted_at).

   ✔ **التحقق النهائي:** آخر صف للمعمورة = ١٦٦٬٦٨٥٫٠١ ولسيدى بشر
   ٢٦٬٩٩٦٫٧٧ — نفس أرقام «الوضع الحالي» بالمليم.

   ⚠️ **فخ الصفوف القديمة في باي موب:** ١٬٢٥٠ صف محصّل بـ
   bank_settled_at فاضي (قبل ١٤/٠٩). لو عدّيناهم «غير محصّل» في كل
   لحظة ماضية الرقم يتضخّم لـ٨١٠ ألف بدل ٢٤ ألف — فبيتستبعدوا صراحةً.
   **والعكس في انستاباي:** الصف المرحّل بلا posted_at اترحّل *قبل*
   نافذتنا فبيتعدّ مرحّلًا دايمًا — وده الصح.

   ⚠️ **شرط الورديات المتصالحة** (`pending > 0 OR not covered`) زي
   get_visa_recon. من غيره الرقم بيجمع فروق مطابقة قديمة ويطلع ١٧٠ ألف
   بدل ٣٦ ألف.

   ⚡ **الأداء — ٣ تقديرات غلط قبل القياس:**
   الدالة بدأت ٧ ثواني. التجسيد (materialized) زوّدها، وتحويل حلقة
   انستاباي لـjoin واحد وحده ماكفاش. القياس بالـEXPLAIN كشف السببين:
     ١) `branch_code_of()` على كل صف بيلغي استعمال الفهارس → بنحلّ
        أسماء الفرع **مرة واحدة** من القيم المميّزة ونقارن بالمساواة.
     ٢) متغيّرات plpgsql بتخلّي المخطّط يعمل خطة عامة: نفس الجسم
        بقيم صريحة ٣٢٠ مللي وبالمتغيّرات ٤ ثواني → الاستعلام بيتبني
        بـ`format()` بقيم صريحة (نفس أسلوب get_jard_stale).
   مع فهرس `wallet(branch, createdAt)`: **٧ ثواني → ٨٦٩ مللي**.

   ملاحظة: الفروع اللي مالهاش تقفيلات (السيوف) بترجع قائمة فاضية.
   ============================================================ */

create index if not exists ix_bank_tx_source_at
  on public.bank_transactions (source, tx_at) where amount > 0;

create index if not exists ix_wallet_branch_created
  on public.wallet (branch, "createdAt");

create or replace function public.get_visa_shift_history(
  p_branch text,
  p_days   integer default 14
) returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_code   text;
  v_fcs    bigint;
  v_bal    numeric;
  v_days   integer := greatest(coalesce(p_days, 14), 1);
  v_since  timestamptz := now() - make_interval(days => greatest(coalesce(p_days,14),1));
  v_floor  timestamptz;
  v_cov    timestamptz;
  v_snames text[];
  v_wnames text[];
  v_out    jsonb;
begin
  if coalesce(current_setting('request.jwt.claims', true),'') <> '' then
    perform public.require_app_role(array['admin','manager','accountant']);
  end if;

  v_code := public.branch_code_of(p_branch);
  if v_code is null then
    return jsonb_build_object('success', true, 'rows', '[]'::jsonb);
  end if;
  /* ٦٠ يوم قبل النافذة: الورديات الأقدم من كده مستحيل تساهم في
     انستاباي (أقدم حركة غير مرحّلة ٣٠/٠٩) وشرط «غير مغطّى» بيخص
     الورديات الحديثة بس. */
  v_floor := v_since - interval '60 days';

  select e.fcs_id, e.balance into v_fcs, v_bal
    from eplus_safes e
   where e.branch = v_code and lower(btrim(coalesce(e.name_ar,''))) = 'visa'
   limit 1;
  if v_fcs is null then
    return jsonb_build_object('success', true, 'branch',
             (select b.name from branches b where b.code = v_code), 'rows', '[]'::jsonb);
  end if;

  select array_agg(b) into v_snames
    from (select distinct branch b from pos_shifts where branch is not null) z
   where public.branch_code_of(b) = v_code;
  select array_agg(b) into v_wnames
    from (select distinct branch b from wallet where branch is not null) z
   where public.branch_code_of(b) = v_code;
  if v_snames is null then
    return jsonb_build_object('success', true, 'branch',
             (select b.name from branches b where b.code = v_code), 'rows', '[]'::jsonb);
  end if;

  select max(t.tx_at) into v_cov
    from bank_transactions t where t.source = 'instapay' and t.amount > 0;

  execute format($q$
    with sh as (
      select s.id, s.closed_at, s.employee_name,
             lag(s.closed_at) over (order by s.closed_at) prev,
             (select coalesce(sum(l.closing_balance),0) from pos_shift_lines l
               where l.shift_id = s.id and l.method_type = 'wallet') wallets,
             (select coalesce(sum(l.actual_amount),0) from pos_shift_lines l
               where l.shift_id = s.id and l.method_key = 'instapay') declared
        from pos_shifts s
       where s.branch = any(%L::text[]) and s.closed_at is not null
         and s.closed_at >= %L::timestamptz
    ),
    pt as (select * from sh where closed_at >= %L::timestamptz),
    ibr as (
      select s2.id shift_id, t.amount, t.is_posted, t.posted_at
        from sh s2
        join bank_transactions t
          on t.source = 'instapay' and t.amount > 0
         and t.tx_at > s2.prev and t.tx_at <= s2.closed_at
       where s2.prev is not null
    ),
    pair as (
      select p.closed_at pc, s2.id sid, s2.declared, s2.closed_at sclosed,
             coalesce(sum(r.amount) filter
               (where r.is_posted and (r.posted_at is null or r.posted_at <= p.closed_at)), 0) posted,
             count(r.*) filter
               (where not (r.is_posted and (r.posted_at is null or r.posted_at <= p.closed_at))) pending
        from pt p
        join sh s2 on s2.prev is not null and s2.closed_at <= p.closed_at
        left join ibr r on r.shift_id = s2.id
       group by p.closed_at, s2.id, s2.declared, s2.closed_at
    ),
    ins as (
      select pc, sum(greatest(declared - posted, 0)) insta
        from pair
       where pending > 0 or sclosed > least(%L::timestamptz, pc)
       group by pc
    ),
    calc as (
      select p.closed_at, p.employee_name, p.wallets,
        %L::numeric - coalesce((select sum(case when c.to_type = 3 and c.to_id = %s
                                                then c.amount else -c.amount end)
              from cashier_transactions c
             where c.branch = %L
               and ((c.to_type = 3 and c.to_id = %s) or (c.from_type = 3 and c.from_id = %s))
               and c.actual_date > p.closed_at at time zone 'Africa/Cairo'), 0) visa,
        coalesce((select sum(x.ammount) from wallet x
           where x.branch = any(%L::text[])
             and coalesce(x.is_excess,false) = false
             and not (coalesce(x.done,false) and x.bank_settled_at is null)
             and x."createdAt" <= p.closed_at
             and (x.bank_settled_at is null or x.bank_settled_at > p.closed_at)), 0) paymob,
        coalesce((select i.insta from ins i where i.pc = p.closed_at), 0) insta
      from pt p
    ),
    fin as (
      select closed_at, employee_name, visa, wallets, paymob, insta,
             visa - wallets - paymob - insta gap,
             (visa - wallets - paymob - insta)
               - lead(visa - wallets - paymob - insta) over (order by closed_at desc) delta
        from calc
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'closed_at', to_char(f.closed_at at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI'),
        'employee',  f.employee_name,
        'visa',      round(f.visa,2),
        'wallets',   round(f.wallets,2),
        'paymob',    round(f.paymob,2),
        'insta',     round(f.insta,2),
        'src_total', round(f.wallets + f.paymob + f.insta, 2),
        'gap',       round(f.gap,2),
        'delta',     round(f.delta,2)
      ) order by f.closed_at desc), '[]'::jsonb) from fin f
  $q$, v_snames, v_floor, v_since, v_cov, v_bal, v_fcs, v_code, v_fcs, v_fcs,
       coalesce(v_wnames, array[]::text[]))
  into v_out;

  return jsonb_build_object(
    'success', true,
    'branch',  (select b.name from branches b where b.code = v_code),
    'days',    v_days,
    'rows',    coalesce(v_out, '[]'::jsonb));
end $function$;

revoke all on function public.get_visa_shift_history(text, integer) from public, anon;
grant execute on function public.get_visa_shift_history(text, integer) to authenticated;
