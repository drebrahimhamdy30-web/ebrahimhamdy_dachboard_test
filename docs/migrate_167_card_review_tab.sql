/* ════════════════════════════════════════════════════════════════
   تبويب «مراجعة تحصيل بطاقات الائتمان»  (2026-10-29)
   ----------------------------------------------------------------
   طلب المالك: موظف مخصّص يراجع **كل** حركات الفيزا والمحافظ ورا
   بعض — مش محصور بشيفت واحد.

   ⚠️ القرار المهم: **مش شاشة جديدة ولا جدول جديد.** التبويب بيستعمل
   نفس جدول تفاصيل الشيفت بالحرف — نفس الأعمدة ونفس `drawRows` ونفس
   زر «تم» ونفس القفل — والفرق الوحيد إن المصدر مش شيفت واحد.
   عشان كده `get_card_txns` بترجّع الصفوف **بنفس شكل**
   `get_current_shift.transactions` بالظبط، فالجدول بيرسمها من غير
   أي تعديل. (المالك صحّح لي ده بعد ما عرضت عليه تصميم مختلف.)

   • المصدر: `cashier_transactions` حيث `is_visa = 1`
     (≈ ٣٬٩٠٠ حركة/شهر على ١٧ قناة: أورنج كاش · فودافون كاش ·
      انستاباي · باي موب ١–٧ · فوري…).
   • المراجعة نفسها: `review_shift_txn` زي ما هي — الدالة أصلًا
     بتشتغل على أي حركة مش مشروطة بشيفت مفتوح، فالحركة اللي تتراجع
     هنا بتبان مراجَعة في الشيفت كمان والعكس.
   • الصف المُراجَع **بيفضل مكانه** ويتقفل من غير إعادة تحميل، عشان
     الموظف ما يفقدش مكانه وهو بيراجع ورا بعض.
   • الفرع بيتاخد من الصف نفسه مش من فلتر الشاشة — التبويب بيعرض
     كل الفروع مع بعض.

   الصلاحية: التبويب اتسجّل في `app_page_tabs`، و**ممنوع افتراضيًا
   لكل الأدوار ما عدا الأدمن** عشان المالك يديه لمين يختار.
   ⚠️ قايمة الأدوار اتجابت من `page_permissions` مش مكتوبة بالإيد —
   أي دور جديد مابينساش.

   يتطبّق على: السحابة (اتعمل 2026-10-29) **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

create or replace function public.get_card_txns(
  p_branch text default null,
  p_from   date default null,
  p_to     date default null,
  p_only_pending boolean default false,
  p_limit  int default 50,
  p_offset int default 0
) returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_from date; v_to date; v_lim int; v_off int; v_out jsonb;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  v_from := coalesce(p_from, (now() at time zone 'Africa/Cairo')::date);
  v_to   := coalesce(p_to,   (now() at time zone 'Africa/Cairo')::date);
  v_lim  := greatest(1, least(coalesce(p_limit, 50), 200));
  v_off  := greatest(0, coalesce(p_offset, 0));

  with t as (
    select c.branch, c.fh_id, c.actual_date, c.amount, c.channel, c.visa_no,
           c.user_name, c.computer, c.notes, c.from_name, c.to_name,
           (c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1) as manual,
           case when c.visa_no ~ '^[0-9]+(\.[0-9]+)?$' and c.visa_no::numeric > 1
                then c.visa_no::numeric else c.amount end as paid_val,
           r.reviewed_by, r.reviewed_at, r.paid as rv_paid, r.channel as rv_channel
      from cashier_transactions c
      left join shift_txn_reviews r on r.branch = c.branch and r.fh_id = c.fh_id
     where coalesce(c.is_visa,0) = 1
       and c.actual_date >= v_from
       and c.actual_date <  v_to + 1
       and (p_branch is null or c.branch = p_branch)
       and (not coalesce(p_only_pending,false) or r.fh_id is null)
  )
  select jsonb_build_object(
    'total',        (select count(*) from t),
    'total_paid',   (select coalesce(sum(paid_val),0) from t),
    'reviewed',     (select count(*) from t where reviewed_by is not null),
    'reviewed_paid',(select coalesce(sum(coalesce(rv_paid, paid_val)),0) from t where reviewed_by is not null),
    'pending',      (select count(*) from t where reviewed_by is null),
    'pending_paid', (select coalesce(sum(paid_val),0) from t where reviewed_by is null),
    'branches',     (select coalesce(jsonb_agg(distinct branch),'[]'::jsonb) from t),
    'channels',     (select coalesce(jsonb_agg(distinct coalesce(channel,'—')),'[]'::jsonb) from t),
    'users',        (select coalesce(jsonb_agg(distinct user_name) filter (where user_name is not null),'[]'::jsonb) from t),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'fh_id', fh_id, 'branch', branch,
        'rv', case when reviewed_by is null then null else jsonb_build_object(
                 'by', reviewed_by,
                 'at', to_char(reviewed_at at time zone 'Africa/Cairo','HH24:MI'),
                 'paid', rv_paid, 'channel', rv_channel) end,
        'date', to_char(actual_date,'YYYY-MM-DD'),
        'time', to_char(actual_date,'HH24:MI'),
        'kind', 'فيزا', 'channel', channel, 'visa_no', visa_no,
        'paid', paid_val, 'manual', manual,
        'party', coalesce(to_name, from_name),
        'from', from_name, 'to', to_name,
        'user_name', user_name, 'amount', amount,
        'computer', computer, 'notes', notes, 'is_sarf', false
      ) order by ord), '[]'::jsonb)
      from (select *, row_number() over (order by actual_date desc, fh_id desc) ord
              from t order by actual_date desc, fh_id desc
             limit v_lim offset v_off) p)
  ) into v_out;
  return v_out;
end $fn$;

revoke all on function public.get_card_txns(text, date, date, boolean, int, int) from public, anon;
grant execute on function public.get_card_txns(text, date, date, boolean, int, int) to authenticated;

/* ── تسجيل التبويب في شاشة الصلاحيات ─────────────────────────── */
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order)
values ('current_shift','cardreview','مراجعة تحصيل بطاقات الائتمان','#tabs .tab[data-mode="cards"]', 4)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

/* ممنوع افتراضيًا لكل الأدوار ما عدا الأدمن — المالك هو اللي يمنحه.
   الأدوار من القاعدة مش مكتوبة بالإيد. */
insert into public.tab_permissions (page_key, tab_key, role, allowed)
select 'current_shift','cardreview', r.role, false
  from (select distinct role from page_permissions where role <> 'admin') r
on conflict (role, page_key, tab_key) do nothing;
