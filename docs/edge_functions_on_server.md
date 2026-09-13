# نقل الـEdge Functions على السيرفر — المطلوب من المبرمج

**السيرفر:** `supabase.ebrahimhamdy.com` (Supabase self-hosted) · **التاريخ:** 2026-09-13

---

## الهدف

الـ15 دالة الشغّالة دلوقتي على سحابة Supabase تشتغل على السيرفر كمان، **ومصدرها الريبو** (`supabase/functions/`) مش لوحة تحكم — عشان أي تعديل يتراجع في Git وينتشر لوحده.

**النتيجة المطلوبة:** المالك يقدر ينشر تعديل من غير ما يستنى حد.

---

## ١) مجلد الدوال + مزامنة من Git

الدوال في الريبو كده:

```
supabase/functions/
├── BASELINE.json          ← لقطة الإصدارات (مش دالة)
├── README.md
├── apk-publish/index.ts
├── change-password/index.ts
└── … 15 مجلد
```

**المطلوب:**

- يتحطوا في الـvolume بتاع حاوية `edge-runtime` (عادةً `volumes/functions/`)
- مهمة دورية (**كل ٥ دقايق**) تعمل `git pull` للريبو وتنسخ `supabase/functions/*` للمجلد
- الريبو: `https://github.com/drebrahimhamdy30-web/ebrahimhamdy_dachboard_test` فرع `main`
- `BASELINE.json` و`README.md` يتستثنوا — مش دوال

---

## ٢) `verify_jwt` — مهم جدًا

على السحابة دي **خاصية لكل دالة**. على السيرفر الراوتر الرئيسي هو اللي بيقرر، فلازم تتظبط يدويًا.

**٣ دوال محمية (`verify_jwt = true`) — لازم ترفض أي نداء بلا توكن صالح:**

| الدالة | ليه |
|---|---|
| `db-restore` | بتكتب فوق قاعدة البيانات كلها |
| `eplus_proxy` | بتضرب نظام eplus الحقيقي |
| `pharma_search` | بتضرب API مورّد خارجي |

**١٢ دالة مفتوحة (`verify_jwt = false`)** — دي **مش سايبة**، الحراسة جوّه الكود نفسه (مفتاح cron أو دور من التوكن)، والتطبيقات بتناديها من غير توكن مستخدم:

```
apk-publish · change-password · create-driver · db-backup · delivery-performance
driver-mark · driver-poll · eplus_sync · pharma_sync · send-fcm
set-driver-active · trip-return-perf
```

⚠️ **لو حطّيت `verify_jwt=true` على الـ12 دول، تطبيق الطيارين هيقف.**

---

## ٣) متغيّرات البيئة (الأسرار)

تتحط على حاوية `edge-runtime`:

| المتغيّر | بيستعمله | ملاحظة |
|---|---|---|
| `SUPABASE_URL` | كل الدوال | رابط السيرفر نفسه |
| `SUPABASE_SERVICE_ROLE_KEY` | كل الدوال | بتاع السيرفر مش السحابة |
| `SERVICE_ROLE_KEY` | بعض الدوال | نفس القيمة — الاسمين مستعملين |
| `SYNC_KEY` | `eplus_sync` · `pharma_sync` | مفتاح الكرون |
| `EPLUS_BRANCHES` | `eplus_proxy` · `eplus_sync` | JSON فيه base + user:pass لكل فرع |
| `EPLUS_BASE` · `EPLUS_BASIC` | احتياطي لفرع واحد | اختياري |
| `PHARMA_MARKET_AUTH` | `pharma_search` · `pharma_sync` | بيانات دخول المورّد |
| `GOOGLE_MAPS_API_KEY` | حساب المسافات | |

> ⚠️ **الأسرار دي تتعمل بقيم جديدة مش نسخة من السحابة.** لو السيرفر اتخرق، السحابة تفضل سليمة والعكس. (استثناء: `EPLUS_BRANCHES` و`PHARMA_MARKET_AUTH` بيانات دخول أنظمة خارجية فهي نفسها.)

---

## ٤) Vault — ٦ أسرار

٦ دوال بتقرا أسرارها من `vault` مش من متغيّرات البيئة:
`apk-publish` · `db-backup` · `db-restore` · `delivery-performance` · `driver-poll` · `trip-return-perf`

**المطلوب على قاعدة السيرفر:**

```sql
select vault.create_secret('<قيمة-جديدة>', 'apk_publish_secret');
select vault.create_secret('<قيمة-جديدة>', 'backup_trigger_token');
select vault.create_secret('<قيمة-جديدة>', 'driver_app_secret');
select vault.create_secret('<قيمة-جديدة>', 'eplus_sync_key');
select vault.create_secret('<قيمة-جديدة>', 'perf_functions_secret');
select vault.create_secret('<قيمة-VAPID>',  'مفتاح الخدمة لإرسال الإشعارات');
```

**وكمان:** الدالة `public.vault_secret(text)` لازم تكون موجودة على السيرفر — دي جسر لأن `vault` مش مكشوف لـPostgREST. **محتاج تأكيد إنها اتنقلت مع السكيما.**

---

## ٥) صلاحية نشر للمالك

المطلوب طريقة **المالك ينفّذها بنفسه** من غير المبرمج. أي واحدة من دول:

- **سكربت** يتنفّذ بأمر واحد: `git pull` + نسخ + (إعادة تشغيل لو لازم)
- **Portainer** بحساب محدود الصلاحية — ⚠️ مش مكشوف على الإنترنت، وعليه تحقق بخطوتين
- **ويبهوك** محمي بمفتاح يشغّل نفس السكربت

---

## ٦) أسئلة محتاج إجابتها

1. **هل `edge-runtime` بيقرا الدالة من القرص عند كل نداء، ولا بيخزّنها ومحتاج إعادة تشغيل؟** ده بيحدّد لو المزامنة لوحدها تكفي ولا لازم restart بعدها.
2. **إعادة تشغيل حاوية `edge-runtime` بتوقّف الخدمة كام ثانية؟** ولو هي ثواني، تتعمل في وقت هادي.
3. **مواصفات السيرفر** (RAM / CPU) — محتاجينها عشان نعرف نقدر نشغّل مزامنات تقيلة ولا لأ.
4. **النسخ الاحتياطي للسيرفر** — ⚠️ لحد دلوقتي **مفيش**. ده أخطر بند في الملف ده.

---

## ⚠️ تحذير لازم يتقري قبل التشغيل

**ماينفعش الكرون يشتغل على السيرفر والسحابة في نفس الوقت.**

- `send-fcm` / `driver-poll` → **الطيارين هياخدوا إشعارات مزدوجة**
- `eplus_sync` / `pharma_sync` → ضغط مضاعف على نفس أنظمة eplus والمورّد، وبيانات ممكن تتضارب

الترتيب الآمن: **الدوال تتنشر على السيرفر وهي ساكنة، والكرون يتشغّل عليها بعد ما السحابة تتوقف.**

مهام الكرون الحالية على السحابة موثّقة في `docs/migrate_09_safety_isolation.sql`.

---

## المرفقات في الريبو

| الملف | فيه إيه |
|---|---|
| `supabase/functions/README.md` | تعليمات النشر التفصيلية |
| `supabase/functions/BASELINE.json` | لقطة الإصدارات — لكشف أي انحراف |
| `docs/migrate_09_safety_isolation.sql` | عزل السيرفر عن التشغيل الحيّ |
