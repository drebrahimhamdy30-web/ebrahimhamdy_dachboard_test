# الخروج من n8n — جدول القرار

**تاريخ المسح:** 2026-09-12 · **الطريقة:** تحليل وصول (reachability) على `api.js` + مسح نداءات الشاشات المباشرة.

> ⚠️ **حدود المسح:** تحليل نصّي. دالة بتتنادى ديناميكيًا (`window[name]`) مش هتتشاف، فـ«ميت» معناها «مفيش نداء مباشر ظاهر» مش ضمان مطلق. قبل حذف أي حاجة، أكّد من لوحة n8n إن الويبهوك مافيهوش نداءات فعلية.

---

## الخلاصة

**n8n مش حاجة واحدة.** الشغل بينقسم تلات فصائل، و«الربط المباشر» بيحل واحدة بس:

| الفصيلة | العدد | الحل |
|---|---|---|
| ⚰️ بقايا كود ميتة | 8 | حذف — مفيش شغل |
| 😴 احتياطي نايم | 3 | حذف بعد التأكد |
| 🟢 حيّ + نقطة eplus جاهزة | 4 | ربط مباشر (سهل) |
| 🟡 حيّ ومحتاج نقطة جديدة | 10 | ربط مباشر (شغل) |
| 🔴 n8n بيعمل شغل حقيقي | 4 | **الربط المباشر مايحلّهاش** |

**أهم اكتشاف:** أكتر من نص اللي شكله «ارتباط بـn8n» مش شغّال أصلًا.

---

## ⚰️ بقايا ميتة — حذف مباشر

مفيش أي طريق ليها من أي شاشة (ولا حتى من جوّه `api.js`):

| الدالة / المكان | الويبهوك |
|---|---|
| `fetchSms` · `insertSms` (api.js) | `bmonline` |
| `fetchPaymob` · `postPaymob` (api.js) | `paymobtransaction` |
| `fetchFullJardReport` (api.js) | `jard_full_report` |
| `updateDataWithResponse` (api.js) | `taskmanagement` |
| `postShiftClose` (api.js) | `posupdate` |
| `INV_URL` في `cosmo_order.html` | `inventory` — ثابت معرَّف ومش مستعمل |

⚠️ `bank_monitor.html` بيستعمل نداءاته الخاصة (`BM_GET`/`BM_POST`/`IMPORT_URL`) — مش دوال `api.js` دي. فحذف `fetchSms`/`insertSms` **مابيأثرش** على شاشة البنك.

---

## 😴 احتياطي نايم — الدخول

`login` · `verify_token` · `forgot_password`

**مابيشتغلوش.** `verifyToken()` بترجع بدري للجلسات على Supabase:

```js
if (localStorage.getItem('authProvider') === 'supabase') {
  const p = sbDecodeJwt(localStorage.getItem('authJwt') || '');
  if (p && p.exp && p.exp * 1000 > Date.now() + 60000) return true;
  return await sbAuthRefresh();     // ← عمره ما بيوصل لـn8n
}
```

الـ٢٤ شاشة اللي بتنادي `verifyToken()` **إنذار كاذب** — كلهم بيقفوا عند السطر ده.

نفس الحكاية في `login()`: Supabase الأول، وn8n لو فشل بس. ده كان مقصود وقت النقل عشان مفيش لحظة قفل.

**القرار:** يتساب لحد ما نتأكد إن مفيش حساب بيقع على الاحتياطي، وبعدين يتشال.

---

## 🟢 حيّ + النقطة موجودة خلاص

دول أسهل مكسب — نقطة eplus معمولة بالفعل في شاشة «الربط بالمصادر»:

| الشاشة | الويبهوك | النقطة الجاهزة |
|---|---|---|
| `price_check.html` — `searchItemLive()` | `inventory?code=&branch=` | **item** (id 8) `/api/Item/SearchItem` |
| `customers.html` — `fetchFromDashboard` · `updateCustomer` | `dashboard?type=` | **customer** (id 7) `/api/Customer/SearchCustomer` |
| `inventory.html` — الرصيد اللحظي | `get_balance` | **item** (id 8) — نفس المصدر |
| `inventory_management.html` | `inventory?type=branch_updates` | نقطة جديدة صغيرة |

⚠️ نقطة **customer** (id 7) فيها الباراميتر مقلوب (`key:"1"` / `value:"cust_active_search"`) — لازم تتصلّح الأول زي ما اتعمل مع «التوصيل».

---

## 🟡 حيّ ومحتاج نقطة جديدة

| الشاشات | الويبهوك | ملاحظة |
|---|---|---|
| `driver.html` · `dispatch.html` · `prep.html` | `sales_item` | ٣ شاشات على نفس المصدر — تتعمل مرة واحدة |
| `dispatch.html` | `lifependingorder` | طلبات معلّقة مش مقفولة |
| `driver.html` | `check_prev_trip` | |
| `print_invoice.html` | `invouce` | |
| `machine_import.html` | `posmanagement` · `posupdate` | |
| `inventory.html` · `main.html` · `jard_settings.html` | `inventory_audit_erp` · `jard_items` · `jard_audit_log` · `jard_stale_report` · `jard_settings_manage` | الجرد — ٤ ويبهوكس حيّة |
| `claims.html` · `contracts_stats.html` | `get_order` | |
| `expenses.html` | `webhook/<path>` — بحث عميل | |

⚠️ **مزامنة الطلبات** مش في الجدول ده لأنها **مش ويبهوك** — n8n بيكتب في `orders` بـ**اتصال مباشر بقاعدة البيانات**. دي أخطر قطعة وليها خطة منفصلة.

---

## 🔴 n8n بيعمل شغل حقيقي — الربط المباشر مايحلّهاش

| الويبهوك | بيعمل إيه | البديل |
|---|---|---|
| `bmonline` · `bmonlinepost` · `updatebmonlne` | مراقبة البنك — **بيستقبل رسائل SMS** | محتاج مستقبِل تاني، مش نقطة eplus |
| `taskmanagement` (`claim_new`) | **سجلات المطالبات متخزّنة جوّه n8n** | جدول في Supabase + نقل البيانات |

دول n8n فيهم مش «وسيط لـeplus» — هو **المخزن** أو **المستقبِل**. إلغاؤهم مشروع منفصل.

---

## الترتيب المقترح

| # | الخطوة | الخطورة |
|---|---|---|
| 0 | تأكيد من لوحة n8n إن الويبهوكس الميتة مافيهاش نداءات | — |
| 1 | حذف البقايا الميتة (٨) | 🟢 صفر |
| 2 | تصليح باراميتر نقطة `customer` | 🟢 صفر |
| 3 | `price_check` + `inventory` → نقطة **item** | 🟢 قراءة بحتة |
| 4 | `customers` → نقطة **customer** | 🟢 |
| 5 | `inventory_management` (`branch_updates`) | 🟢 |
| 6 | `print_invoice` + `machine_import` | 🟡 معزولة |
| 7 | الجرد (٤ ويبهوكس) | 🟡 |
| 8 | `sales_item` (٣ شاشات) | 🟠 بيمسّ الطيارين |
| 9 | `lifependingorder` + `check_prev_trip` | 🟠 |
| 10 | مزامنة الطلبات (اتصال مباشر بالقاعدة) | 🔴 **الأخطر** |
| 11 | المطالبات — نقل جدول من n8n | 🔴 مشروع منفصل |
| 12 | مراقبة البنك — مستقبِل رسائل | 🔴 مشروع منفصل |
| 13 | حذف احتياطي الدخول | 🟢 بعد التأكد |

**المنطق:** نثبّت الأنبوبة على حاجات لو وقعت مش هتأذي حد، وبعدين نطلع للحاجات اللي الطيارين والتوزيع معتمدين عليها.
