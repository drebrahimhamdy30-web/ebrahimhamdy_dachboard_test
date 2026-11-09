# مزامنة المخزون الفرقية — مواصفة وركفلو n8n

> الحالة: جاهزة للتنفيذ على **المعمورة** بس. التلات فروع التانية تفضل
> على الوركفلو القديم لحد ما المعمورة تتأكد بالمقارنة مع eplus.
>
> طرف القاعدة: `docs/migrate_198_stock_upsert.sql` (لازم يتطبّق الأول).

---

## ليه نافذة ثابتة بدل «آخر نجاح»

الفكرة الأولى كانت نخزّن «آخر مزامنة ناجحة» ونجيب من عندها. وده بيورّث
مشكلتين عندنا تاريخ معاها:

1. **أي ختم وقت بيكدب في وقت ما** — `synced_at` كدب في ١٧ جدول،
   و`updated_at` كدب في المخزون، وساعة الأجهزة كدبت وقفلت الدخول.
2. **لو الختم اتكتب والجولة فشلت بعده**، الحركة اللي بينهم تضيع للأبد
   ومحدش يعرف.

**الحل: مفيش حالة أصلًا.** كل جولة بتجيب **آخر ٢٤ ساعة** من الحركة.

| | |
|---|---|
| حجم الجلب | ~1,300 صنف (4.7% من الجدول) |
| لو المزامنة وقعت ٧ ساعات | **بتلحق نفسها** في أول جولة ناجحة |
| حالة محفوظة | **ولا حاجة** |
| ساعة متضبوطة | مش شرط (النافذة أوسع من أي انحراف معقول) |

الإعادة مش مشكلة — الـupsert بيكتب نفس القيمة. والتكلفة 1,300 صف
بدل 27,821 يعني **95% أقل** وإحنا كاسبين الصيانة الذاتية كمان.

> حادثة 2026-11-09 (٧ ساعات توقف) كانت هتتصلّح لوحدها مع النافذة دي.

---

## الوركفلو الفرقي — ٥ عقد

### ١. Schedule Trigger
كل **10 دقايق**.

### ٢. Code — النافذة
```javascript
// DateTime (Luxon) متاحة جوّه عقد الكود في n8n.
// ⚠️ لازم القاهرة صراحةً — السيرفر UTC، والفرق ساعتين (أو تلاتة
//    صيفًا) كفيل إنه يضيّع حركة لو حسبناها بتوقيت السيرفر.
const since = DateTime.now()
  .setZone('Africa/Cairo')
  .minus({ hours: 24 })
  .toFormat("yyyy-MM-dd'T'HH:mm:ss");

return [{ json: { since, branch: 'mamora' } }];
```

### ٣. HTTP Request — الكميات
```
POST  https://eplus.ebrahimhamdy.com/api/Item/SearchItem
Auth: Basic (eplus)
Body: { "itm_lasttrans_date_search": "{{ $json.since }}",
        "page_no": 1, "page_size": 5000 }
Settings: Retry On Fail = 3 محاولات / 5 ثواني · Timeout 120000
```
> `https` مباشرة مش `http` — بيوفّر تحويلة الـ301.

### ٤. HTTP Request — الأسعار والأسماء
نفس العقدة بالظبط، بس:
```
Body: { "itm_update_date_search": "{{ $('Code').item.json.since }}",
        "page_no": 1, "page_size": 5000 }
```
> **ليه نداءين:** `last_trans_date` ختم سجل **الكميات**
> (`watch_qty_chng`). تغيّر السعر مابيحركوش. من غير النداء ده الأرصدة
> هتبقى مظبوطة والأسعار تتجمّد. (المقاس: ~350 صنف بياناته بتتعدّل
> يوميًا.)

### ٥. Code — دمج وإزالة التكرار
```javascript
const a = $('الكميات').all().map(i => i.json);
const b = $('الأسعار').all().map(i => i.json);

const map = new Map();
for (const r of [...a, ...b]) {
  if (r && r.itm_code) map.set(String(r.itm_code), r);   // الأحدث يغلب
}
const rows = [...map.values()];

// حارس: جولة بترجّع صفر غالبًا نداء فاشل اتبلع، مش يوم بلا حركة
if (!rows.length) throw new Error('مفيش ولا صنف — راجع النداءين');

return [{ json: { p_branch: 'mamora', p_rows: rows } }];
```

### ٦. HTTP Request — الكتابة
```
POST  {SUPABASE_URL}/rest/v1/rpc/upsert_branch_stock
Headers: apikey: {SERVICE_ROLE} · Authorization: Bearer {SERVICE_ROLE}
         Content-Type: application/json
Body: {{ JSON.stringify($json) }}
```
الرد:
```json
{ "branch": "mamora", "rows": 1312, "affected": 1312, "at": "..." }
```

---

## الوركفلو الليلي — لقطة كاملة

مرة واحدة الساعة **3 ص**. غرضه الوحيد: **الأصناف المحذوفة من eplus**
(الفرقية بتغطّي كل حاجة تانية بصفر فقدان — اتأكد على يوم ويومين
وأسبوع وشهر).

### ١. Code — جلب كل الصفحات في عقدة واحدة
```javascript
const PAGE = 5000, MAXP = 50;
let all = [], page = 1;
while (true) {
  const r = await this.helpers.httpRequest({
    method: 'PATCH',
    url: 'https://eplus.ebrahimhamdy.com/api/Item/SearchItem',
    auth: { username: 'eplus', password: '...' },
    body: { page_no: page, page_size: PAGE },
    json: true, timeout: 120000,
  });
  const rows = Array.isArray(r) ? r : (r.data || r.items || []);
  all = all.concat(rows);
  if (rows.length < PAGE) break;
  if (++page > MAXP) throw new Error('الصفحات تخطّت الحد');
}
if (all.length < 20000) throw new Error(`جلب ناقص: ${all.length} صف`);
return [{ json: { started: new Date().toISOString(), rows: all } }];
```
**الجلب كله في عقدة واحدة بقصد** — لو صفحة وقعت، العقدة كلها تقع
ومايتكتبش ولا صف. مفيش احتمال نص جدول.

### ٢. upsert على دفعات
نفس `rpc/upsert_branch_stock`، الصفوف مقسّمة 5,000 لكل نداء.

### ٣. الكنس
```
POST {SUPABASE_URL}/rest/v1/rpc/sweep_branch_stock
{ "p_branch": "mamora", "p_since": "<started>",
  "p_max_pct": 10, "p_apply": true }
```
بيمسح اللي ماتحدّثش في الجولة، **ويرفض** لو هيمسح أكتر من 10%.

> **ليه ده أأمن من `Swap Tables`:** الجلب لو وقع في النص، اللي وصل
> بيتحدّث واللي ماوصلش بيفضل **بقيمته القديمة مش صفر**، والكنس
> بيترفض. ومفيش لحظة واحدة الجدول فيها ناقص. حادثة سيدى بشر بتبقى
> **مستحيلة هيكليًا** مش متحارَس ضدها.

---

## ترتيب التحويل

| | الخطوة | ملاحظة |
|---|---|---|
| ١ | طبّق `migrate_198` | دوال بس — صفر تغيير سلوك |
| ٢ | **أوقف وركفلو المعمورة القديم** | لازم قبل اللي بعده |
| ٣ | شغّل الليلي **مرة يدويًا** | بيملا الجدول ويختمه كله |
| ٤ | فعّل الفرقي كل 10 دقايق | |
| ٥ | **مقارنة بـeplus صنف بصنف** | بعد يوم |
| ٦ | كرّر على التلات فروع | بعد ما ٥ تطلع نضيفة |

⚠️ **٢ و٣ ورا بعض فورًا.** القديم بيعمل `Swap` بيمسح التريجر ويدوس
على أي upsert — فالاتنين مايشتغلوش مع بعض.

⚠️ **بعد آخر `Swap Tables`** أعِد تشغيل الجزء (٣) من `migrate_198`
(التريجر) — الـrename بيموّته.

---

## التحقق (خطوة ٥)

مش «المفروض يبقى مظبوط» — مقارنة مباشرة. عندنا قراءة على `Genius`،
فبنجمع رصيد كل صنف من `Item_Class_Store` (مخزن 1) ونطابقه بجدولنا:

```
27,821 صنف  →  كام صنف رصيده مختلف؟
```

**صفر = نجاح بالدليل.** أي فرق يتفحص قبل ما نلمس فرع تاني.
