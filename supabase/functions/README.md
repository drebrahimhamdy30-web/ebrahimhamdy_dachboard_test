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
