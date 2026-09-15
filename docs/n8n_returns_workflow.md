# نقل «المرتجعات» من شاشة الربط لـn8n

مواصفات النقطة الشغّالة دلوقتي (`integration_endpoints` id=4) عشان الوركفلو الجديد يطلع **مطابق**.

---

## 🔴 الفخ الأخطر — اقراه قبل أي حاجة

eplus بيبعت التاريخ كده:

```json
"return_bill_date": "2026-09-15 20:12:46"
```

**نص عادي من غير أي علامة توقيت.** وعمود `returns_log.return_date` نوعه
`timestamp without time zone` — يعني بيتخزّن **بتوقيت القاهرة الحرفي**.

وn8n عندك متظبّط على `Africa/Cairo (UTC+03:00)`.

يعني لو الوركفلو عمل:

```javascript
new Date(r.return_bill_date).toISOString()      // ⛔ ممنوع
```

هيفسّره كقاهرة ويحوّله UTC → **`17:12:46` بدل `20:12:46`**. تلات ساعات فرق في كل مرتجع،
من غير أي رسالة خطأ، والشاشات تقرا أرقام غلط.

**القاعدة: عدّي النص زي ما هو.** مافيش `new Date` ولا `toISOString` ولا أي تحويل.

(نفس الغلطة حصلت قبل كده في `picked_at`/`delivered_at` واتصلّحت لـ٨٢٣ طلب.)

---

## المواصفات

| | |
|---|---|
| Method | `PATCH` |
| Path | `/api/ReturnSalesBillItem/SearchReturnBillItem` |
| Auth | Basic (نفس credential `eplus`) |
| الجدول الهدف | `returns_log` |
| مفتاح الـupsert | `branch, bill_no, itm_code, unit_ar, return_date` |
| التكرار | كل **٦٠** دقيقة |
| الفروع | **التلاتة** — المعمورة · سان ستيفانو · سيدى بشر |

### الباراميترز

| المفتاح | القيمة (تعبير n8n) |
|---|---|
| `bill_from_date_search` | `={{ $now.minus({hours:2}).format('yyyy-MM-dd HH:mm:ss') }}` |
| `bill_to_date_search` | `={{ $now.format('yyyy-MM-dd HH:mm:ss') }}` |

⚠️ `.format()` هي الصيغة الشغّالة في n8n (اتجرّبت). `.toFormat()` الـLuxon الأصلية
مش مضمونة هنا — ونفس `.format()` هي اللي مستعملة في نقاط شاشة الربط، فالصيغة موحّدة.

⚠️ النافذة **ساعتين** والجولة **كل ساعة** — التداخل مقصود: لو جولة فشلت،
اللي بعدها بتغطّي مكانها. والـupsert بيمنع التكرار.

### ماب الحقول (١٢ + الفرع)

| من eplus | لـ`returns_log` |
|---|---|
| `return_bill_no` | `bill_no` |
| `return_bill_type` | `return_type` |
| `return_bill_date` | `return_date` ⚠️ نص زي ما هو |
| `itm_code` | `itm_code` |
| `itm_name` | `itm_name_ar` |
| `u_name_ar` | `unit_ar` |
| `u_name_en` | `unit_en` |
| `itm_back_qty` | `back_qty` |
| `itm_back_price` | `back_price` |
| `int_code` | `int_code` |
| `cust_code` | `cust_code` |
| `cust_name` | `cust_name` |
| — | `branch` = اسم الفرع (بيتحط من الوركفلو) |

⚠️ قيم `branch` لازم تطابق الموجود بالحرف: `المعمورة` · `سان ستيفانو` · `سيدى بشر`
(لاحظ **سيدى** بألف مقصورة). أي اختلاف = صفوف مكرّرة بدل ما تتحدّث.

---

## نود Code — التحويل

```javascript
const BRANCH = 'المعمورة';          // غيّرها في نسخة كل فرع

const rows = $input.first().json.Data || [];

return rows.map(r => ({ json: {
  branch:      BRANCH,
  bill_no:     r.return_bill_no,
  return_type: r.return_bill_type,
  return_date: r.return_bill_date,   // ⚠️ نص زي ما هو — ممنوع new Date()
  itm_code:    r.itm_code,
  itm_name_ar: r.itm_name,
  unit_ar:     r.u_name_ar,
  unit_en:     r.u_name_en,
  back_qty:    r.itm_back_qty,
  back_price:  r.itm_back_price,
  int_code:    r.int_code,
  cust_code:   r.cust_code,
  cust_name:   r.cust_name,
}}));
```

## نود Postgres

| | |
|---|---|
| Operation | **Insert or Update** |
| Table | `returns_log` |
| Matching Columns | `branch` · `bill_no` · `itm_code` · `unit_ar` · `return_date` |

---

## الشكل

```
Schedule Trigger (60د)
   ├─→ HTTP المعمورة    →  Code (BRANCH='المعمورة')    ─┐
   ├─→ HTTP سان ستيفانو →  Code (BRANCH='سان ستيفانو') ─┼─→ Postgres (upsert)
   └─→ HTTP سيدى بشر    →  Code (BRANCH='سيدى بشر')    ─┘
```

عناوين الـbase لكل فرع موجودة في سر `EPLUS_BRANCHES`
(لوحة Supabase → Edge Functions → Secrets).

---

## خطة التحويل الآمنة

1. ابني الوركفلو وشغّله **يدوي مرة** — ماتجدولوش
2. سيب النقطة القديمة شغّالة — الاتنين بيعملوا `upsert` بنفس المفتاح، فالتكرار مستحيل
3. **قارن بعد يوم** بالاستعلام تحت
4. لو مفيش فروق → أوقف جدولة النقطة القديمة
5. راقب يوم كمان قبل ما تمسحها

```sql
-- لازم يرجّع صفر صفوف
select branch, bill_no, itm_code, count(*)
from public.returns_log
where created_at > now() - interval '1 day'
group by 1,2,3 having count(*) > 1;
```

⚠️ الاتنين شغّالين مع بعض = ضغط مضاعف على eplus (اللي واقع أصلًا).
خلّي فترة التوازي **يوم واحد** بس.
