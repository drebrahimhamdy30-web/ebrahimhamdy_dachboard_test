-- ═══════════════════════════════════════════════════════════════════
--  «تم» على حركة قيمة مدفوعها > 0 لازمها صورة تحويل
-- ═══════════════════════════════════════════════════════════════════
--  قيمة مدفوع أكبر من صفر معناها فلوس اتحوّلت فعلًا لحساب محفظة،
--  فصورة التحويل هي إثبات إن التحويل حصل. من غيرها الإقفال بيبقى
--  ضغطة بلا دليل.
--
--  ⚠️ العطل اللي الملف ده بيصلّحه (المالك 2026-11-15):
--     الحارس كان في المتصفح بس، وجوّه `maybeDisburse` كده:
--         if(!hasImg) return;        // خروج صامت
--     يعني «تم» من غير صورة كان: الصف **يتراجع ويتقفل**، الصرف
--     مايحصلش، **وولا رسالة تظهر**. الموظف يفتكر إن كله تمام،
--     والفلوس ما اتصرفتش، والصف مقفول فمحدش هيرجعله.
--
--  ⚠️ والواجهة مش حارس أصلًا: `review_shift_txn` تتنادى مباشرة
--     فتعدّي. فالحارس الحقيقي لازم يكون هنا.
--
--  الصور في `txn_receipts (kind='card', branch, ref_id = fh_id::text)`
--  — راجع migrate_211.
--
--  ملاحظة على الصياغة: `to_char(..,'FM...')` بتاكل الصفر اللي قدام
--  الكسر فـ0.25 تطلع «.25»، وبتسيب نقطة في الآخر لـ150 («150.»).
--  `trim_scale(numeric)::text` بتدي 150 · 1234.5 · 0.25 زي ما هي.
--
--  اتجرّب على السحابة 2026-11-15 جوّه ترانزاكشن اتلغى — ٥ حالات:
--    مدفوع 150 / 1234.5 / 0.25 بلا صورة  →  اترفضت بالرسالة الصح
--    مدفوع 0                              →  عدّت
--    مدفوع 150 ومعاها صورة                →  عدّت
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.review_shift_txn(
  p_branch   text,
  p_fh_id    bigint,
  p_paid     numeric default null,
  p_channel  text    default null,
  p_note     text    default null,
  p_note_src text    default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare v_by text;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  if not exists (select 1 from cashier_transactions c
                  where c.branch = p_branch and c.fh_id = p_fh_id) then
    raise exception 'الحركة غير موجودة' using errcode = 'P0002';
  end if;
  if exists (select 1 from shift_txn_reviews r
              where r.branch = p_branch and r.fh_id = p_fh_id) then
    raise exception 'تمت مراجعة هذه الحركة بالفعل' using errcode = '23505';
  end if;

  /* مدفوع > 0 = فلوس اتحوّلت لحساب محفظة، والصورة إثبات التحويل.
     حارس سيرفر لأن الواجهة مش حارس — الدالة تتنادى مباشرة فتعدّي. */
  if coalesce(p_paid, 0) > 0
     and not exists (select 1 from public.txn_receipts t
                      where t.kind = 'card'
                        and t.branch = p_branch
                        and t.ref_id = p_fh_id::text) then
    raise exception 'قيمة المدفوع % ج — يُرجى إرفاق صورة التحويل قبل التأكيد',
      trim_scale(p_paid)::text using errcode = 'P0001';
  end if;

  v_by := public.bank_actor();
  insert into shift_txn_reviews (branch, fh_id, paid, channel, note, note_src, reviewed_by)
  values (p_branch, p_fh_id, p_paid,
          nullif(btrim(coalesce(p_channel,'')),''),
          nullif(btrim(coalesce(p_note,'')),''),
          case when p_note_src in ('typed','auto') then p_note_src end, v_by);
  return jsonb_build_object('success', true, 'reviewed_by', v_by,
                            'reviewed_at', to_char(now() at time zone 'Africa/Cairo','HH24:MI'));
end $function$;

comment on function public.review_shift_txn(text,bigint,numeric,text,text,text) is
  'تأكيد مراجعة حركة شيفت. مدفوع > 0 لازمه صورة تحويل في txn_receipts (حارس سيرفر، مش الواجهة).';

notify pgrst, 'reload schema';
