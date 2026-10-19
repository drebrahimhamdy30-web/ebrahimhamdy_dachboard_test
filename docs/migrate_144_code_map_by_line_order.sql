/* ============================================================
   قاموس أكواد المشتريات: المطابقة بترتيب السطر بدل السعر والكمية
   ------------------------------------------------------------
   المشكلة: `build_purchase_code_map` كان بيربط سطر الإكسل بسطر
   الفاتورة بـ(الفرع + المسلسل + سعر الشراء + الكمية). لو صنفين في
   **نفس الفاتورة** ليهم نفس الكمية ونفس السعر (شائع جدًا: شامبو
   وبلسم بنفس التسعيرة)، سطر الإكسل بيلاقي سطرين، فالدالة بترفض
   الاتنين (`having count(distinct code)=1`) — وده قرار سليم، التخمين
   كان هيحط كود الشامبو على البلسم.

   النتيجة إن ٦٬٦٧١ بند من ١٣٬٠٤٢ بلا كود (٥١٪) كانوا محجوبين لنفس
   السبب، ورفع الشيت تاني ماكانش بيحلها أبدًا. والبند بلا كود مخفي
   تمامًا عن بحث التكلفة (`search_item_cost` بيستبعد
   `coalesce(itm_code,'') <> ''`).

   الحل: نستعمل **ترتيب السطر**. اتأكد على بيانات حقيقية:
     san/17524 → ملف: 9794, 53911, 71657  ·  عندنا ptd_id 1,2,3:
                 9794, 53911, 71657 ✓
     (والسطر الأول itm_id=25382 وكوده 9794 — مختلفين، فالترتيب هو
      اللي ربطهم، مش الرقم.)

   ⚠️ ملف الإكسل **مافيهوش** عمود «م» (موجود على الشاشة بس مش
   بيتصدّر) — فالترتيب بيتحسب من ترتيب الصفوف في الملف، والسكربت
   بقى يرقّمها جوّه كل فاتورة ويبعتها في `line_no`.

   ⚠️ الترتيب لوحده مش كفاية: لو بند اتحذف من الفاتورة ممكن يحصل
   إزاحة. فبنستعمل الترتيب **للتفرقة** وبنفضل نشترط تطابق السعر
   والكمية **للتأكيد** — أي زوج ترتيبه طابق وأرقامه مااتطابقتش
   بيتساب. يعني الترتيب بيفك الالتباس من غير ما يفتح باب التخمين.

   ⚠️ الصفوف القديمة اللي `line_no` فيها فاضي بتمشي بالطريقة القديمة
   بالحرف — عشان نسخة سكربت قديمة ما تعملش ضرر صامت.
   ============================================================ */
alter table public.purchase_xlsx_stage
  add column if not exists line_no integer;

comment on column public.purchase_xlsx_stage.line_no is
  'ترتيب السطر جوّه الفاتورة كما ورد في ملف الإكسل (يطابق purchase_invoice_items.ptd_id).';

create or replace function public.build_purchase_code_map()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_mapped int; v_applied int;
begin
  with
  /* (أ) المسار الجديد: ترتيب السطر — بيفكّ التوائم */
  f_ord as (
    select s.branch, s.pth_id, s.code, s.name, s.qty, s.pur,
           row_number() over (partition by s.branch, s.pth_id order by s.line_no) as rk
      from purchase_xlsx_stage s
     where s.line_no is not null
  ),
  d_ord as (
    select pi.branch, pi.pth_id, pi.itm_id, pi.qnty, pi.itm_pur_price,
           row_number() over (partition by pi.branch, pi.pth_id order by pi.ptd_id) as rk
      from purchase_invoice_items pi
  ),
  j_ord as (
    select d.branch, d.itm_id, f.code, f.name
      from f_ord f
      join d_ord d
        on d.branch = f.branch and d.pth_id = f.pth_id and d.rk = f.rk
       /* التأكيد: الترتيب فكّ الالتباس، والأرقام بتثبت إن مفيش إزاحة */
       and round(d.itm_pur_price::numeric, 2) = round(f.pur::numeric, 2)
       and round(d.qnty::numeric)             = round(f.qty::numeric)
  ),
  /* (ب) المسار القديم بالحرف — للصفوف اللي مالهاش ترتيب */
  j_old as (
    select distinct pi.branch, pi.itm_id, s.code, s.name
      from purchase_xlsx_stage s
      join purchase_invoice_items pi
        on pi.branch = s.branch and pi.pth_id = s.pth_id
       and round(pi.itm_pur_price::numeric, 2) = round(s.pur::numeric, 2)
       and round(pi.qnty::numeric)             = round(s.qty::numeric)
     where s.line_no is null
  ),
  j as (
    select * from j_ord
    union
    select * from j_old
  ),
  /* نفس الحارس القديم: صنف طلع له أكتر من كود = مايتكوّدش */
  good as (
    select branch, itm_id from j group by branch, itm_id having count(distinct code) = 1
  )
  insert into item_code_map(branch, itm_id, itm_code, itm_name, source)
  select j.branch, j.itm_id, max(j.code), max(j.name), 'purchase_xlsx'
    from j join good g on g.branch = j.branch and g.itm_id = j.itm_id
   group by j.branch, j.itm_id
  on conflict (branch, itm_id) do update
    set itm_code = excluded.itm_code, itm_name = excluded.itm_name, updated_at = now();
  get diagnostics v_mapped = row_count;

  v_applied := apply_item_code_map();
  truncate public.purchase_xlsx_stage;
  return jsonb_build_object('mapped', v_mapped, 'applied', v_applied);
end$function$;
