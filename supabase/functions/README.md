# Edge Functions

⚠️ **الريبو ده عام (public).** أي حاجة هنا مقروءة لأي حد على الإنترنت.

## القاعدة
**ممنوع** كتابة أي توكن أو مفتاح أو كلمة سر في ملفات الدوال.
كل سر ييجي من متغيّر بيئة:

```ts
const TOKEN = Deno.env.get("MY_TOKEN") ?? "";
if (!TOKEN) return new Response("unauthorized", { status: 401 });   // فاضي = ممنوع
```

الأسرار تتظبط من: Supabase → Edge Functions → Secrets.

## سابقة
`db-backup` كان فيه `TRIGGER_TOKEN` مكتوب صريح واترفع هنا. اتكشف على
GitHub، فاتشال من الملف **واتغيّر** — شيله من الملف لوحده مش كفاية،
لأن الـgit history بيفضل شايله.

## الدوال
| الدالة | مين بينادها |
|---|---|
| `db-backup` | cron يومي (`db-backup-daily`) |
| `eplus_sync` | cron (`eplus_sync_tick`) + `integrations.html` |
| `send-fcm` | trigger `notify_fcm_on_assign` على `orders` |
| `delivery-performance` | triggers `trg_delivery_perf` و `trg_fail_perf` |
| `trip-return-perf` | trigger `trg_trip_return_perf` على `trips` |
| `eplus_proxy` | شاشات الـERP |
| `pharma_sync` | `store_prices.html` |
| `driver-poll` / `driver-mark` / `create-driver` / `set-driver-active` / `change-password` | تطبيق السواقين |
| `apk-publish` / `db-restore` / `pharma_search` / `pharma_probe` | أدوات إدارية |
| `clever-action` / `swift-api` / `send-push` | مفيش مستدعي — مرشّحة للحذف |

## مصدر الأسرار: متغيّر بيئة ولا vault؟

الاتنين مقبولين — المهم إنه **مش في الملف**:

| الدالة | مصدر سرها | ليه |
|---|---|---|
| `eplus_sync` | `Deno.env.get("SYNC_KEY")` | الأبسط لما السر بتاع الدالة نفسها |
| `db-backup` | vault عبر `vault_secret()` | الـcron بينادي الدالة، فلازم الاتنين يقروا نفس القيمة |
| `delivery-performance` / `trip-return-perf` | vault عبر `vault_secret()` | نفس السبب — التريجرات بتنادي الدالة |

`public.vault_secret(text)` دالة وسيطة `SECURITY DEFINER` صلاحيتها
لـ`service_role` بس، لأن سكيما `vault` نفسها مش معروضة لـPostgREST.

⚠️ لو سر vault اتمسح أو رجع فاضي، الدالة **ترفض** — مش تسمح للكل.
الشرط دايمًا `if (!expected || provided !== expected) return 401`.

### الأسرار المخزّنة في vault دلوقتي
| الاسم | بيستعمله |
|---|---|
| `backup_trigger_token` | `db-backup` + كرونتين النسخ الاحتياطي |
| `perf_functions_secret` | دالتين الأداء + 4 دوال قاعدة بيانات |
| `driver_app_secret` | نسخة من سر تطبيق السواقين (قبول انتقالي) |
| `eplus_sync_key` | نفس قيمة `SYNC_KEY` — عشان الـcron مايكتبهاش صريح |

تغيير قيمة `eplus_sync_key` لوحدها **مش كفاية**: الدالة بتقارن
بـ`SYNC_KEY` من متغيّرات البيئة، فلازم الاتنين يتغيّروا مع بعض.

## قبل ما تصدّر دالة هنا
افحصها من الأسرار الأول:
```bash
grep -nE '=\s*["'"'"'][A-Za-z0-9_./+-]{16,}["'"'"']' supabase/functions/*/index.ts
```

## الفحص التلقائي
```bash
node scripts/check-secrets.js
```
شغّال تلقائيًا قبل كل commit عبر `.githooks/pre-commit`.
لتفعيله على نسخة جديدة من الريبو:
```bash
git config core.hooksPath .githooks
```

### أسرار الدوال — الحالة بعد 2026-09-04

| الدالة | السر | المصدر |
|---|---|---|
| `db-backup` · `db-restore` | `backup_trigger_token` | vault |
| `delivery-performance` · `trip-return-perf` | `perf_functions_secret` | vault |
| `driver-poll` | `driver_app_secret` | vault (نفس قيمة الـAPK) |
| `apk-publish` | `apk_publish_secret` | vault — **مستقل** عن سر التطبيق |
| `eplus_sync` · `pharma_sync` | `SYNC_KEY` | متغيّر بيئة |
| `pharma_*` | `PHARMA_MARKET_AUTH` | متغيّر بيئة |

🔴 **`db-restore` كان شايل نسخة من التوكن المسرّب** بعد ما دوّرته في
`db-backup` — أي حد قرا تاريخ الريبو كان يقدر يكتب فوق القاعدة كلها.
**لما تدوّر سر، اعمل grep عليه في كل الدوال مش اللي فاكر إنها بتستعمله.**

🔴 **سر تطبيق الطيارين منشور** في ريبو `phalix-driver-app` العام
(workflow + `lib/config.dart`). `apk-publish` اتفصلت عنه فورًا عشان
مايتستعملش لاستبدال الـAPK. تغيير السر نفسه محتاج إصدار جديد.

✅ **إنذار كاذب:** `OAUTH_SECRET="secret"` في `pharma_*` = قيمة SAP
Commerce الافتراضية، مش سر. اتأكد قبل ما «تصلّح».

---

## النشر على سيرفر خاص (self-hosted)

### الدوال المصدَّرة: 15
كل دالة في مجلدها ومعاها `.meta.json` فيه `verify_jwt` الصح —
مهم يتظبط عند النشر، غلطة فيه بتفتح دالة للعامة أو تقفل دالة مطلوبة.

### ⚠️ ماتنشرش من غير ما تقرا ده

**1. عزل الأثر الخارجي أولًا.** شغّل `docs/migrate_09_safety_isolation.sql`
**قبل** أول نشر. من غيره:
· أي تعديل طلب على السيرفر بيبعت **إشعار حقيقي لطيار شغّال**
· تريجرات الأداء بتستهلك حصة Google Maps المدفوعة

**2. ماتحطّش المتغيّرات دي على سيرفر التجربة:**
· `FCM_SERVICE_ACCOUNT` — من غيرها الإشعارات بتفشل بهدوء (حزام أمان)
· مفتاح Google Maps — من غيره حساب الأداء بيقف
دول يتحطوا يوم التحويل الحقيقي بس.

**3. ماتشغّلش كرونات المزامنة** (`eplus_sync_tick`، pharma):
دي بتضرب **أنظمة خارجية** — eplus وAPI فارما. تشغيلها من السيرفر
يعني ضغط مضاعف على نفس الحسابات اللي الإنتاج شغّال عليها.

**4. `db-backup` أول دالة تتنشر مش آخر واحدة.** السيرفر دلوقتي من
غير أي نسخة احتياطية — وده أخطر بند في القايمة كلها.

### متغيّرات البيئة المطلوبة (9)
`VAPID_PUBLIC_KEY` · `VAPID_PRIVATE_KEY` · `VAPID_SUBJECT` ·
`FCM_SERVICE_ACCOUNT` · `EPLUS_BRANCHES` · `EPLUS_BASE` ·
`EPLUS_BASIC` · `SYNC_KEY` · `PHARMA_MARKET_AUTH`

(Supabase بتوفّر `SUPABASE_URL` و`SUPABASE_SERVICE_ROLE_KEY` و
`SUPABASE_ANON_KEY` لوحدها.)

### أسرار vault المطلوبة
`driver_app_secret` · `perf_functions_secret` · `backup_trigger_token` ·
`apk_publish_secret` · `eplus_sync_key`

⚠️ اعملها بقيم **جديدة** على السيرفر — مش نفس قيم السحابة. لو حد
اخترق التست مايوصلش للإنتاج.

### دوال مش مصدَّرة عن قصد
| الدالة | السبب |
|---|---|
| `clever-action` · `swift-api` | قوالب Supabase فاضية مالهاش مستدعي — **للحذف** |
| `pharma_probe` | معطّلة (بترجّع 410) |
| `send-push` | إشعارات ويب VAPID — تتصدّر لو هتتستعمل |
