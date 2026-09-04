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
