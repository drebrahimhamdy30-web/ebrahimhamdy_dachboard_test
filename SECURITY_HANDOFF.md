# مستند تسليم — تأمين نظام Phalix للبيع (Security Hardening)

> **الغرض:** ابدأ جلسة Claude Code جديدة مخصّصة لإصلاحات الأمان بس. المستند ده مكتفٍ بذاته — اقرأه بالكامل قبل أي تعديل. الجلسة اللي عملت التدقيق تركت التنفيذ ليك.
>
> **تاريخ التدقيق:** 2026-08-26 · **مبني على فحص مباشر للـDB — تحقّق من كل رقم/سياسة قبل التنفيذ لأن الحالة بتتغيّر.**

---

## 0) حقائق أساسية (لا تتخطاها)

- **Supabase project id:** `rxtjoqulmgkkcohmgzgi` (قاعدة واحدة مشتركة بين التست والبرودكشن).
- **ريبوهين لازم يتطبّق عليهم أي تعديل كود:**
  - تست: `C:\Users\Kimo Store\Documents\GitHub\ebrahimhamdy_dachboard_test`
  - برودكشن: `C:\Users\Kimo Store\Documents\GitHub\ebrahimhamdy_dachboard`
- **قواعد الشغل (من CLAUDE.md):** انقل الملفات المتفرّعة **جراحيًا** مع الحفاظ على **CRLF في البرودكشن**؛ نسخ كامل بس بعد التأكد إن `diff --strip-trailing-cr` بيبيّن تعديلك فقط. `driver.html`, `transfers.html`, `api.js`, `main.html`, `app.html`, `dispatch.html`, `orders.html` **متفرّعة** — جراحي إجباري. **parse-check** للـ`<script>` (استخراج + `new Function()`) قبل أي push. رسائل commit عربية تشرح «الليه». cache-bust للـJS المشترك بـ`?v=`.
- **تعديلات الـDB مشتركة = بتأثّر على الريبوهين فورًا.** service_role key في n8n بس، ماينزلش في الكود.
- **⚠️ النظام لايف وشغّال — أي إغلاق صلاحية ممكن يكسر شاشة. اشتغل جدول-جدول واختبر بعد كل خطوة. خُد باك-أب قبل أي عملية خطرة.**

---

## 1) ملخص التدقيق (الوضع الحالي)

**الحكم:** غير جاهز أمنيًا للبيع، لكن قابل للإصلاح (الأساسيات موجودة).

**الثغرة الجوهرية:** مفتاح `anon` العام (ظاهر في كود أي صفحة) بيدّي **قراءة + كتابة + حذف** لمعظم الجداول.

### أرقام مفتاحية
- 101 جدول public — **كلها anon-writable** (بصلاحيات الجدول level grants).
- 78 جدول anon-readable.
- 12 جدول **RLS مقفول (rowsecurity=false)** = مكشوف تمامًا.
- 127 دالة `SECURITY DEFINER` — **14 بس محمية** بـ`require_app_role`، **113 غير محمية** (anon يقدر ينفّذها بصلاحيات المالك).

### 🔴 جداول مالية/تشغيلية مكشوفة (سياسة `using(true)` لـanon — قراءة+كتابة+حذف)
`contracts` · `sales_items` · `erp_expenses` · `pos_shifts` (public) · `pos_wallet_transfers` · `wallet` (public SELECT+UPDATE)

### 🟠 الـ12 جدول RLS مقفول تمامًا (rowsecurity=false)
`stock_mamora` · `stock_san` · `stock_bishr` · `stock_flat_meta` · `branch_stores` · `gift_campaigns` · `gift_list` · `order_store_override` · `sales_price_review_exclusions` · `ex_archived_items` · `code_sugg_queue` · `archived_items_backup_20260824`
> ملاحظة: `stock_*` بتتكتب من n8n (مزامنة eplus) — أي RLS جديد لازم يسمح للخدمة (service_role) تكتب، والعرض قراءة بس.

---

## 2) ✅ محمي بالفعل — **ماتكسرهوش**

- **الباسوردات:** `branch_users` و`password_resets` → RLS شغّال **بدون policy** = محجوب عن anon تمامًا. الباسورد `password_hash` (مُجزّأ). سليم.
- **`orders`:** عليه policy لـ`authenticated` + شرط حقيقي (مش `using(true)`) — **ده النموذج الصح، اتبعه لباقي الجداول.**
- **جداول محجوبة (RLS + بدون policy):** `pos_transactions` · `paymob_transactions` · `driver_debug` · `jard_erp` · `jard_category_flags` · `driver_push_subscriptions`.
- **Storage:** `db-backups` خاص ✅. `branding` و`driver-apk` عامّين (مقبول).
- **نظام أدوار قائم:** دخول بيرجّع JWT موقّع (n8n) → `localStorage.authJwt` → `jwt_app_role()` + `require_app_role(allowed text[])`. 14 عملية محمية بالفعل.
- **الأدوار:** admin / manager / pharmacist / inventory / employee (localStorage.userRole؛ والدور الحقيقي جوّه الـJWT).

---

## 3) خطة الإصلاح — مرحلية

### 🟢 المرحلة 0 — مكاسب سريعة (ابدأ بيها؛ مخاطرة منخفضة، من غير لمس الدخول)
1. **تفعيل RLS على الـ12 جدول المكشوف.** لكل واحد: `alter table X enable row level security;` + policy قراءة للعرض `for select to anon,authenticated using(true)` (مؤقتًا لحد المرحلة 2)، ومنع الكتابة من anon (الكتابة عبر service_role/n8n اللي بيتخطّى RLS تلقائيًا). **اختبر الشاشة اللي بتقرا كل جدول بعد التفعيل.**
   - انتبه: أي شاشة بتكتب في الجداول دي من المتصفح هتقع — راجع الاستخدام الأول (`stock_*` تُكتب من n8n مش المتصفح؛ `gift_*`, `branch_stores`, `order_store_override` راجعهم).
2. **مراجعة الـ113 دالة SECURITY DEFINER غير المحمية.** استعلام الحصر:
   ```sql
   select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prokind='f' and p.prosecdef
     and pg_get_functiondef(p.oid) not ilike '%require_app_role%';
   ```
   - اللي **بتكتب/بتحذف أو بتكشف بيانات حسّاسة** → أضِف `perform require_app_role(array['admin',...]);` في أولها، أو `revoke execute ... from anon;`.
   - اللي **قراءة/تجميع للعرض** (get_*, report_*) → غالبًا آمنة، سيبها.
3. **إلغاء صلاحيات anon الكتابية غير المستخدمة** على الجداول اللي مفيش شاشة بتكتب فيها من المتصفح.

### المرحلة 1 — المصادقة: Supabase Auth بدل n8n
- فعّل Supabase Auth، هجّر المستخدمين من `branch_users` (أول دخول يعيد تعيين الباسورد، لأن الهاش مايتقراش).
- الأدوار في `app_metadata`، وRLS تقرا `auth.jwt()->>'app_role'` أو profiles table.
- الصفحات تستخدم توكن جلسة Supabase (بدل authJwt من n8n). الـ`db` client في `delivery/app.html` بياخد Bearer authJwt — بدّل المصدر.
- أوقف اعتماد توقيع JWT على n8n (السر يرجع جوّه Supabase بس).

### المرحلة 2 — إغلاق anon (جدول-جدول، تدريجي)
- لكل جدول: إلغاء سياسة anon، وسياسة `to authenticated using(<شرط الدور/الفرع>)` — زي `orders`.
- الترتيب: المالي الأول (`contracts`, `wallet`, `pos_*`, `erp_expenses`, `sales_items`)، وبعدها الباقي.
- الصفحات لازم كلها تبعت توكن المستخدم (مش anon key) — دي أكبر شغلة كود.

### المرحلة 3 — العزل (حسب نموذج البيع)
- **نسخة لكل عميل** (موصى بيها للبداية): مشروع Supabase + نشر مستقل لكل عميل = عزل فيزيائي. محتاج **طريقة تجهيز نسخة بسرعة** (سكريبت migration كامل للـschema + زرع `org_settings` + إنشاء أدمن).
- **SaaS**: `tenant_id` على كل جدول + RLS يفلتر بالـtenant. أقوى بس أكبر وأخطر.

---

## 4) القرارات المفتوحة (محتاجة رأي المالك)
- **نموذج البيع** لسه غير محسوم. التوصية: ابدأ single-tenant (نسخة/عميل). المراحل 0–2 مطلوبة في الحالتين فابدأ من غير ما تستنى القرار.
- تأكيد نطاق كل مرحلة قبل تنفيذها مع المالك (drebrahimhamdy30@gmail.com).

---

## 5) أول خطوة عملية مقترحة
ابدأ **المرحلة 0 خطوة 1**: راجع استخدام كل جدول من الـ12 (فين بيتقرا/بيتكتب في الكود) → فعّل RLS + policy قراءة → اختبر الشاشة. اعملها **جدول واحد كل مرة** وأكّد إن مفيش شاشة وقعت قبل ما تعدّي للتالي. متعملش الـ12 دفعة واحدة.

**تحقّق دايمًا من الحالة الحيّة قبل التنفيذ** (السياسات/الصلاحيات ممكن تكون اتغيّرت):
```sql
-- حالة RLS + صلاحيات anon لأي جدول
select relname, relrowsecurity from pg_class where relname='TABLE_NAME';
select * from pg_policies where tablename='TABLE_NAME';
select privilege_type from information_schema.role_table_grants
where grantee='anon' and table_name='TABLE_NAME';
```

---

## مراجع الذاكرة ذات الصلة
`[[white-label-org-settings]]` · `[[permission-model]]` · `[[user-admin-rpcs]]` · `[[repos-and-db-topology]]` · `[[security-hardening-plan]]`

---

# سجل التنفيذ

## ✅ المرحلة 0 — خطوة 1 (تفعيل RLS على الـ12 جدول) — **تمّت 2026-08-26**

**تصحيح مهم للتدقيق الأصلي:** الفحص الحيّ بيّن إن **6 من الـ12** كانوا محجوبين فعلًا عن anon على مستوى الـgrants (مالهمش `SELECT`) رغم إن `rowsecurity=false`. المكشوف الحقيقي كان **6 جداول** بس. كمان **كل الـ12 كان anon عنده عليهم `TRUNCATE`** — دي ماكانتش في التدقيق واتسحبت كلها.

**طريقة العمل:** جدول واحد كل مرة → فحص استخدامه في **الأربع ريبوهات** → تطبيق → اختبار بمحاكاة دور `anon` (دالة probe مؤقتة، **اتحذفت بعد الانتهاء**) + مقارنة نتائج الـRPCs قبل/بعد.

**نتيجة أساسية:** كل الجداول دي مملوكة لـ`postgres` و`force_rls=false`، وكل الدوال اللي بتلمسها `SECURITY DEFINER` بمالك `postgres` → **RLS مابيأثّرش عليها**. اتثبت عمليًا (`item_lookup`, `get_stock_summary`, `get_shortages`, `get_stock_limits`, `item_balance`, `get_purchase_orders` رجّعوا نفس النتائج بالظبط).

| # | الجدول | الوضع قبل | اللي اتعمل | الاختبار |
|---|--------|-----------|------------|----------|
| 1 | `archived_items_backup_20260824` | anon: TRUNCATE بس | RLS + سحب TRUNCATE | anon محجوب · 738 صف سليم |
| 2 | `ex_archived_items` | anon: TRUNCATE بس | RLS + سحب TRUNCATE | `get_purchase_orders` = 3508 قبل وبعد |
| 3 | `stock_flat_meta` | anon: TRUNCATE بس | RLS + سحب TRUNCATE | `get_stock_summary` سليم |
| 4 | `stock_bishr` | anon: TRUNCATE بس | RLS + سحب TRUNCATE | كل RPCs المخزون مطابقة |
| 5 | `stock_san` | anon: TRUNCATE بس | RLS + سحب TRUNCATE | كل RPCs المخزون مطابقة |
| 6 | `stock_mamora` | anon: TRUNCATE بس | RLS + سحب TRUNCATE | `item_lookup('1452')` رجّع نفس الـJSON |
| 7 | `code_sugg_queue` | 🔴 anon CRUD كامل | RLS + سحب SELECT/INSERT/UPDATE/DELETE/TRUNCATE من anon+authenticated | كله محجوب |
| 8 | `gift_campaigns` | 🔴 anon CRUD كامل | نفس اللي فوق | anon محجوب · دالة SD لسه بتقرا · 1 صف سليم |
| 9 | `gift_list` | 🔴 anon CRUD كامل (بيانات عملاء) | نفس اللي فوق | select/insert/update/delete كلهم محجوبين · 27 صف سليم |
| 10 | `sales_price_review_exclusions` | 🟠 anon SELECT | RLS + سحب SELECT/TRUNCATE | anon محجوب · `enrich_sale_row` لسه بيقرا الـ6 صفوف |
| 11 | `branch_stores` | 🔴 anon CRUD كامل | RLS + سياسات مسموحة + **سحب UPDATE و TRUNCATE** | SELECT/DELETE/INSERT شغّالين (المطلوب للشاشة) · UPDATE+TRUNCATE محجوبين · 18 صف سليم |
| 12 | `order_store_override` | 🔴 anon CRUD كامل | RLS + سياسات مسموحة + **سحب TRUNCATE** | DELETE + upsert شغّالين · TRUNCATE محجوب · 15 صف سليم |

**مفيش أي تعديل كود** — الـ12 كلهم اتظبطوا على مستوى الـDB بس، فمافيش حاجة تتنقل للبرودكشن.

### ⚠️ الجدولين 11 و 12 لسه مكشوفين فعليًا
`branch_stores` و`order_store_override` بيتكتبوا من `medicine_orders.html` بمفتاح **anon مباشر** (سطور 431/449/454 و 809/1000 — متطابقة في الريبوهين). السياسات دلوقتي `using(true)` = **البنية اتحطّت بس الأمان لسه مافيش**. أي حد معاه المفتاح العام يقدر يمسح ارتباطات المخازن. **الحل في المرحلة 2**: RPC محروس بـ`require_app_role(array['admin','inventory'])` بدل الكتابة المباشرة، وبعدين شيل سياسات الكتابة من anon.

### التراجع (Rollback) لو أي شاشة وقعت
```sql
-- لأي جدول من 1–10:
alter table public.<T> disable row level security;
grant select, insert, update, delete, truncate on public.<T> to anon, authenticated;
-- لـ11 و 12: كفاية إرجاع اللي اتسحب
grant update, truncate on public.branch_stores to anon, authenticated;
grant truncate on public.order_store_override to anon, authenticated;
alter table public.branch_stores disable row level security;
alter table public.order_store_override disable row level security;
```

### 🔜 التالي: المرحلة 0 — خطوة 2 (الـ113 دالة SECURITY DEFINER)
لُوحِظ أثناء الشغل ومحتاج تصرّف فوري في الخطوة الجاية:
- **`refresh_stock_flat()` قابلة للتنفيذ من `anon`** — دالة كتابة تقيلة (بتعيد بناء `stock_flat`). أي حد يقدر ينده عليها في لوب = تعطيل الخدمة. مرشّحة أولى لـ`revoke execute from anon`.
- `topup_code_suggestions`, `compute_code_suggestions_batch` — دوال كتابة، راجع صلاحية التنفيذ عليها.

## ✅ المرحلة 0 — خطوة 2 (الدوال SECURITY DEFINER) — **تمّت جزئيًا 2026-08-26**

**تصحيح لأرقام التدقيق:** «113 دالة غير محمية» رقم مضلّل — الاستعلام الأصلي بيفحص `pg_get_functiondef` اللي بيبدأ بـ`CREATE OR REPLACE FUNCTION`، فكل دالة بتطلع «بتعمل CREATE». الفحص الصح على **`prosrc` (جسم الدالة بس)**:

| التصنيف | العدد قبل | بعد |
|---|---|---|
| محمية بـ`require_app_role` | 13 | **14** |
| دوال تريجر (مش قابلة للنداء عبر REST) | 17 | 17 |
| `anon` مالوش تنفيذ | 10 | **20** |
| 🔴 **`anon` ينفّذ + بتكتب** | **28** | **17** |
| 🟢 `anon` ينفّذ + قراءة فقط | 59 | 59 |

### 🔑 اكتشاف حاسم: الصلاحية جايّة من `PUBLIC` مش من `anon`
معظم الدوال `proacl` بتاعها `NULL` أو بيبدأ بـ`=X/postgres` — ودي معناها **EXECUTE ممنوحة لـ`PUBLIC`**. يعني `revoke execute ... from anon` **لوحده مالوش أي تأثير**، لأن anon بيرث من PUBLIC. الصيغة الصح:
```sql
revoke execute on function public.X(args) from public, anon, authenticated;
grant  execute on function public.X(args) to postgres, service_role;   -- cron=postgres · n8n=service_role
```

### اللي اتقفل (11 دالة)
**مجموعة أ — صيانة من cron بس** (`pg_cron` بيشتغل بدور `postgres` فمش متأثر):
`cleanup_empty_trips` · `cleanup_old_logs` · `close_stale_open_sessions` · `recover_stuck_orders` · `refresh_stock_flat` · `topup_code_suggestions`
> أخطرهم `refresh_stock_flat()` — `truncate`+`insert` على `stock_flat` كل 10 دقايق. كانت قابلة للنداء من أي حد معاه المفتاح العام = **تعطيل خدمة بسطر واحد**.

**مجموعة ب — بتتنده من جوّه الـDB بس:**
`compute_code_suggestions_batch` (من topup) · `recompute_trip_total` (من 3 تريجرات) · `refresh_driver_ranks` (من trg_refresh_ranks) · `update_txn_time` (**دالة ميتة** — مفيش مستدعي في أي ريبو ولا تريجر ولا cron)
> اتأكدنا إن كل التريجرات المعنية `SECURITY DEFINER` بمالك `postgres` — لو واحد كان `INVOKER` كان القفل هيكسر إنشاء/تعديل الطلبات.

**مجموعة ج — حراسة بدور:** `set_order_region` → `require_app_role(array['admin','manager','employee','cashier'])`.
> **من غير تعديل كود**: `dispatch.html` بتنده عليها عبر `db` client اللي بيبعت `authJwt`، ونفس الصفحة بتنده `manual_assign_order` المحروسة بنفس الأدوار وشغّالة في البرودكشن = دليل إن الـJWT بيحمل `user_role` صح.

**الاختبارات:** anon اتمنع من الـ11؛ التريجرات لسه بتشتغل (UPDATE على `orders` و`trip_orders` نجحوا داخل transaction اتراجعت)؛ **الـcron نجح فعليًا بعد التعديل** (`cleanup-empty-trips` 22:44 و22:46، `recover-stuck-orders` 22:45). حراسة `set_order_region` اتجرّبت بكل الأدوار: `anon`/`driver`/`pharmacist` ⛔ · `admin`/`manager`/`employee`/`cashier`/`service_role` ✅.

### ⏳ الباقي: 17 دالة كتابة — **محتاجة تعديل كود، مش DB بس**
السبب: الصفحات دي بتبعت **مفتاح anon مباشر** مش `authJwt`، فإضافة `require_app_role` هتكسرها فورًا. لازم الأول الصفحة تبعت التوكن (ده شغل المرحلة 1/2).

| الصفحة | التوكن الحالي | الدوال |
|---|---|---|
| `medicine_orders.html` | anon | `delete_month_sales`, `upload_month_sales`, `mark_item_coded`, `refresh_consumption_rates`, `refresh_purchase_orders` |
| `store_prices.html` | anon | `store_delete`, `store_rename`, `upload_store_sheet` |
| `shift_history.html` | anon | `add_recon_txn`, `move_recon_txn` |
| `inventory.html` | anon | `resolve_jard_audit` |
| `inventory_management.html` | anon | `review_price_change` |
| `delivery/driver.html` + APK | JWT **مع fallback لـanon** | `report_driver_location`, `set_driver_avatar`, `web_driver_fail_order` |
| `delivery/auth.html` + APK | anon **بالتصميم** | `reset_password_with_code`, `reset_password_with_token` |

> **الطيار:** `phalix-driver-app/lib/api.dart:9` = `'Bearer ${jwt ?? Config.supabaseAnonKey}'` — بيرجع لمفتاح anon لو التوكن فاضي. **ماتحرسش دوال الطيار قبل ما تتأكد إن كل المسارات بتبعت JWT**، وإلا الطيارين مش هيقدروا يسجّلوا فشل توصيل.
> **إعادة تعيين الباسورد:** الدالتين **لازم** يفضلوا متاحين لـanon (المستخدم مش داخل أصلًا) — محروسين ذاتيًا بكود/توكن. مش ثغرة.

### 🟠 مكشوف كمان (قراءة) — نفس التبعية على تعديل الكود
`get_cs_orders` و `get_shortages` قابلين للنداء بالمفتاح العام وبيرجّعوا **بيانات عملاء** (`cust_name`, `cust_code`, وأعمدة تليفون). مفيش أي دالة قراءة بترجّع `password_hash` ✅.

### 🔴 ملاحظة جانبية خارج نطاق الخطوة
`cron.job` فيه توكن نسخ احتياطي مكتوب صريح في أمر `db-backup-daily` (`...functions/v1/db-backup?token=...`). `cron.job` مقروء لـ`postgres` بس، فمش مكشوف لـanon — بس التوكن ده بيدّي تشغيل النسخ الاحتياطي لأي حد يعرفه. يُفضّل ينتقل لـVault ويتغيّر.

### التراجع (Rollback) لخطوة 2
```sql
-- إرجاع أي دالة اتقفلت:
grant execute on function public.<الاسم>(<الأنواع>) to anon, authenticated;
-- إلغاء حراسة set_order_region: شيل سطر PERFORM public.require_app_role(...) من تعريفها.
```

---

## ✅ أول صفحة تتحوّل لـ`authJwt`: `store_prices.html` — **تمّت 2026-08-26**

الصفحة كانت بتنده `store_rename` / `store_delete` / `upload_store_sheet` **بمفتاح anon العام**، يعني أي حد يقرا كود أي صفحة يقدر يعيد تسمية مخزن أو يمسحه أو يستبدل شيت أسعار مخزن بالكامل.

### التعديل (سطر واحد اتحوّل لـ12، في الريبوهين)
```js
const SP_AUTH = (function () {
  const t = localStorage.getItem('authJwt');
  try {
    const p = t && JSON.parse(atob(t.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));
    if (p && p.exp * 1000 > Date.now() + 60000) return t;
  } catch (e) {}
  return SB_ANON_API;      // ناقص/منتهي → القراءة تفضل شغّالة
})();
const H = { 'apikey': SB_ANON_API, 'Authorization': 'Bearer ' + SP_AUTH };
```
> **ليه فحص `exp`؟** لأن التوكن المنتهي بيخلّي PostgREST يرجّع **401 على كل حاجة** فالصفحة تقع بالكامل. بالفحص ده الصفحة بترجع لمفتاح anon فالعرض شغّال وأزرار الإدارة بس هي اللي بترفض. **ده أأمن من `supabase-config.js`** اللي بيبعت التوكن من غير أي فحص انتهاء — الصفحات اللي بتستعمله (dispatch/driver/wallet/sms/permissions/machine_import) معرّضة لده. يُفضّل تتنقل لنفس النمط.

### الحراسة (بعد النشر)
الـ3 دوال اتحرست بـ`require_app_role(array['admin','manager','pharmacist'])` — نفس الأدوار اللي الصفحة بتظهرلهم أزرار الإدارة (`pharmacist` = مشتريات).

### ⚠️ الترتيب مهم — ماتعكسهوش
الموقع الحي على **GitHub Pages** (`CNAME` → `phalix.ebrahimhamdy.com`). لو الحراسة اتضافت **قبل** ما الكود يتنشر، الشاشة بتقع في البرودكشن فورًا. الترتيب الصح: **عدّل الكود → commit+push → استنى Pages ينشر → أكّد إن الموقع الحي بيقدّم النسخة الجديدة → بعدين ضيف الحراسة.**

### الاختبارات اللي اتعملت
- ✅ `authenticated` عنده **نفس** صلاحيات `anon` على `stores`, `store_item_prices`, `store_sheet_mappings`, `v_store_item_prices` والسياسات بتغطي الدورين → مفيش تغيير سلوك في القراءة.
- ✅ الصفحة اتحمّلت في المتصفح من التست والبرودكشن والموقع الحي: 30,470 صنف · 50 صف/صفحة · 8 مخازن.
- ✅ مسار «مفيش توكن» ومسار «توكن منتهي» → الاتنين رجعوا لمفتاح anon والصفحة اشتغلت كاملة.
- ✅ الحراسة على الـ3 دوال: `anon`/`driver`/`employee` ⛔ · `pharmacist`/`manager`/`admin`/`service_role` ✅.
- ✅ **من الموقع الحي بمفتاح anon**: `store_rename` رجّع `401 / 42501 — غير مصرّح`.
- ✅ دوال الاقتراحات (`suggest_stock_codes`) لسه شغّالة بـanon (مش محروسة عمدًا — قراءة).
- ⏳ **لسه محتاج تأكيد منك:** الدخول بحساب أدمن حقيقي وتجربة **إعادة تسمية مخزن** — ده المسار الوحيد اللي مقدرتش أختبره (محتاج JWT موقّع من n8n).

### الباقي على نفس النمط
`medicine_orders.html` (5 دوال) · `shift_history.html` (2) · `inventory.html` (1) · `inventory_management.html` (1) — نفس الخطوات بالظبط. ولما `medicine_orders.html` تتحوّل، ساعتها يتقفل `branch_stores` و`order_store_override` كمان.

### 🔧 إصلاح إضافي (سلامة بيانات، مش أمان): `store_rename` / `store_delete` كانوا ناقصين جدولين
اسم المخزن مخزّن في **5 جداول**، والدالتين كانوا بيغطّوا **3** بس:

| الجدول | كان بيتحدّث؟ |
|---|---|
| `stores` · `store_item_prices` · `store_sheet_mappings` | ✅ |
| **`branch_stores`** (أي فرع بيشتري من أي مخزن) | ❌ → ✅ اتصلح |
| **`order_store_override`** (المخزن المختار لكل صنف في الطلبية) | ❌ → ✅ اتصلح |

يعني أي إعادة تسمية لمخزن كانت هتخلّي ربط «طلبيات الأدوية» يشاور على اسم مش موجود. `store_delete` كمان بقى ينضّف الربط المعلّق بدل ما يسيبه يتيم.

**الاختبار (إعادة تسمية حقيقية لـ«تارجت» جوّه transaction اتراجعت):** الخمس جداول اتحركوا مع بعض — `items_moved=23771` · `branch_links_moved=3` · `order_overrides_moved=3` (التلاتة+التلاتة دول هم اللي كانوا هييتّموا). واختبار حذف بمخزن وهمي رجّع `branch_links_removed=1, order_overrides_removed=1` و**بقايا معلّقة=0**.
**بعد الاختبارات:** 7 مخازن · 130,530 صف أسعار · 18 ربط فرع · 15 override · **صفر أسماء يتيمة** · صفر بقايا اختبار. الحراسة لسه قايمة (401 من الموقع الحي بمفتاح anon).

> ملاحظة: مفيش FK بين `branch_stores.store`/`order_store_override.store` وبين `stores.name` — عشان كده الانحراف ده كان ممكن أصلًا. يستاهل يتحط FK لاحقًا.

### 🔒 FK على أسماء المخازن (2026-08-30)
اسم المخزن كان نص حر في 4 جداول من غير أي قيد → أي انحراف ممكن. اتضاف FK على الأربعة → `stores.name`:
`branch_stores` · `order_store_override` · `store_item_prices` · `store_sheet_mappings`

**`ON UPDATE CASCADE` إجباري — مش اختياري.** اتجرّب FK عادي وفشل فورًا:
```
update or delete on table "stores" violates foreign key constraint on table "branch_stores"
```
السبب إن `store_rename` بتغيّر `stores.name` الأول والتوابع لسه شايلة الاسم القديم.

**`ON DELETE` سيبناه افتراضي (NO ACTION)** — `store_delete` بيمسح التوابع الأول، والقيد بقى كمان **بيمنع حذف أي مخزن مربوط مباشرةً من REST**.

**تعديل لازم مع الكاسكيد:** قاعدة البيانات بتحرّك التوابع لحظة تغيير `stores.name`، فالـ`UPDATE`ات الصريحة جوّه `store_rename` بقت بتلاقي صفر صفوف و`items_moved` كان هيرجع **صفر** والشاشة بتعرضه للمستخدم. اتصلح بالعدّ **قبل** تغيير الاسم.

**الاختبارات (كلها جوّه transaction اتراجعت):**
| المسار | النتيجة |
|---|---|
| إعادة تسمية «تارجت» | ✅ `items_moved=23787` (دقيق مش صفر) · `sheet_maps=1` · `branch_links=3` · `order_overrides=5` · الاسم القديم=0 |
| رفع شيت بعد إعادة التسمية | ✅ نجح |
| `store_delete` بمخزن مربوط بالأربعة | ✅ نجح · **بقايا معلّقة=0** |
| إدخال اسم مخزن غير موجود | ✅ **اترفض** |
| حذف مخزن مربوط مباشرةً من `stores` | ✅ **اترفض** (حماية جديدة) |

**بعد كله:** 7 مخازن · 130,846 صف أسعار · 18 ربط فرع · 25 override · 7 ماب · **صفر أسماء يتيمة** · صفر بقايا. الشاشة على الموقع الحي شغّالة (31,492 صنف · 8 مخازن).

> `purchase_orders_flat.best_store` اتستثنى عمدًا — جدول محسوب بيتعاد بناؤه بالكامل من `refresh_purchase_orders()`، فالـFK عليه ممكن يعطّل إعادة الحساب من غير فايدة (مشتق مش مصدر).

---

## ✅ `medicine_orders.html` — تحويل + حراسة + إغلاق الجدولين — **تمّت 2026-08-30**

نفس نمط `store_prices.html` (`MO_AUTH` بفحص `exp`). الصفحة بتلمس **11 جدول + 10 RPCs** — اتأكدنا إن `authenticated` عنده **نفس** صلاحيات `anon` على الـ11 وإن كل السياسات بتغطي الدورين، والـ10 RPCs متاحة لـauthenticated → صفر تغيير سلوك في القراءة.

**الأدوار:** `admin`/`manager`/`pharmacist` — الصفحة نفسها بتحرس كده (`canEdit` = التلاتة، `canOrder` = pharmacist/admin وهي مجموعة فرعية).

### ⚠️ فخ حرج: دالتين مشتركين مع pg_cron
`refresh_purchase_orders` و `refresh_consumption_rates` بيتندهوا من **cron** كمان (`refresh_orders_daily` كل 10 دقايق · `refresh_consumption_daily` يوميًا) ومن **جوّه** `delete_month_sales`/`upload_month_sales`.

**`require_app_role` المباشرة كانت هتكسر الجدولة** — الـcron مالوش `request.jwt.claims` فالدالة بترفض. اتأكدنا عمليًا.

الحل — الحراسة تشتغل بس لو فيه سياق طلب ويب:
```sql
if coalesce(current_setting('request.jwt.claims', true),'') <> '' then
  perform public.require_app_role(array['admin','manager','pharmacist']);
end if;
```
**التفرقة دي مثبتة عمليًا:** نداء REST بمفتاح anon بيجيب `{"role":"anon",...}` (اختُبر من المتصفح على الموقع الحي)، وجلسة cron/SQL بتجيب `NULL`. يعني أي مسار ويب محروس، والـcron والنداء الداخلي بيعدّوا.

### إغلاق `branch_stores` و `order_store_override` (بقايا المرحلة 0)
الكتابة بقت لـ`authenticated` بشرط الدور عبر `jwt_app_role()`، و**اتسحبت صلاحيات INSERT/UPDATE/DELETE من `anon`** خالص.
**القراءة سايبينها مفتوحة عن قصد** — الصفحة بترجع لمفتاح anon لو التوكن منتهي عشان العرض مايقعش، والضرر الحقيقي في الكتابة.

### الاختبارات
| الحالة | النتيجة |
|---|---|
| cron (من غير claims) → الدالتين | ✅ عدّى — والـcron الحقيقي نجح 02:15 بعد التعديل |
| ويب anon → الـ5 دوال | ⛔ كلهم `401 غير مصرّح` |
| JWT driver → refresh_purchase_orders | ⛔ مرفوض |
| pharmacist/manager/admin/service_role | ✅ شغّالين |
| `upload_month_sales` (بينده `refresh_consumption_rates` جوّه) | ✅ النداء المتداخل عدّى |
| anon → قراءة `branch_stores` من الموقع الحي | ✅ 200 |
| anon → حذف `branch_stores` من الموقع الحي | ⛔ **401** |
| driver/employee → حذف من الجدولين | ⛔ **0 صف** |
| pharmacist/admin → حذف/إدخال/upsert | ✅ شغّال |

> **ملاحظة مهمة للاختبار:** RLS على `DELETE`/`UPDATE` **مابيرميش خطأ** — بيأثّر على **0 صف** بهدوء. أي اختبار بيقيس «نجح/فشل» بس هيقول ALLOWED بالغلط. لازم تقيس `row_count`.

**بعد كله:** الصفحة الحيّة شغّالة (13,605 صنف · 100 صف) · `branch_stores`=18 · `order_store_override`=25 · صفر بقايا اختبار.

### الحصيلة
الـ17 دالة المكشوفة بقت **12**. فاضل: `shift_history.html` (2) · `inventory.html` (1) · `inventory_management.html` (1) · دوال الطيار (3) · إعادة تعيين الباسورد (2 — بالتصميم) · `get_cs_orders`/`get_shortages` (قراءة بيانات عملاء).

---

## ✅ التلات صفحات الأخيرة — **تمّت 2026-08-30**

| الصفحة | الدوال | الأدوار | أسلوب التعديل |
|---|---|---|---|
| `shift_history.html` | `add_recon_txn` · `move_recon_txn` | admin · accountant · reviewer · manager | تحويل كامل عند `H_BASE` (نقطة واحدة) |
| `inventory.html` | `resolve_jard_audit` | admin · inventory | **مستهدف** — نداء الدالة بس |
| `inventory_management.html` | `review_price_change` | admin · manager · pharmacist · employee · reviewer | **مستهدف** — نداء الدالة بس |

**ليه مستهدف؟** الصفحتين فيهم 3 و7 مواضع هيدرات متفرّقة. تحويل النداء المحروس بس = مساحة تأثير أصغر بكتير (باقي الاستعلامات تفضل anon زي ما هي)، ومفيش حاجة تانية ممكن تتكسر. `shift_history` فيها نقطة واحدة فالتحويل الكامل كان أنضف.

**مصدر الأدوار:** حراسة كل صفحة في الكود + جدول `page_permissions`. مثلًا `shift_history` = `CAN_EDIT_TXN` (= `canConfirm`)، و`inventory_management` مالهاش حراسة دور في الكود خالص فالأدوار اتاخدت من `page_permissions` (admin/employee/manager/pharmacist/reviewer كلهم ✎).

**الأدوار الحقيقية في `branch_users`:** driver(53) · employee(9) · inventory(6) · manager(3) · cashier(2) · pharmacist(2) · admin(1) · accountant(1) · reviewer(1).

### 🐞 باگ اتصلح على الطريق
`setReviewed` في `inventory_management.html` كانت بتعمل تحديث تفاؤلي وتتراجع **بس لو `fetch` رمى استثناء** — و`fetch` **مابيرميش استثناء على 401/403**. يعني لو الحفظ اترفض، المستخدم يشوف العلامة اتحفظت وهي مااتحفظتش. اتضاف `if(!r.ok) throw`.

### مصفوفة الاختبار (كل الأدوار × كل الدوال)
| الدور | add_recon | move_recon | jard | price_review |
|---|---|---|---|---|
| anon | ⛔ | ⛔ | ⛔ | ⛔ |
| driver | ⛔ | ⛔ | ⛔ | ⛔ |
| employee | ⛔ | ⛔ | ⛔ | ✅ |
| inventory | ⛔ | ⛔ | ✅ | ⛔ |
| accountant | ✅ | ✅ | ⛔ | ⛔ |
| manager | ✅ | ✅ | ⛔ | ✅ |
| admin | ✅ | ✅ | ✅ | ✅ |

**ومن الموقع الحي بمفتاح anon:** الأربعة رجّعوا `401 غير مصرّح`، والصفحة شغّالة (34 صف).
**البيانات سليمة:** wallet_sms=4850 · jard محلولة=471 · price_changes مراجَعة=2919 · صفر معاملات يدوية مضافة.

### ⚠️ نهايات الأسطر مختلفة لكل ملف — اتحقق قبل كل نقل
`shift_history.html`=CRLF · `inventory.html`=**LF** · `inventory_management.html`=CRLF · `medicine_orders.html`=**LF** · `store_prices.html`=CRLF.
القاعدة العامة «CRLF في البرودكشن» **مش صحيحة لكل الملفات** — اقيس بنفسك.

### الحصيلة
دوال الكتابة المكشوفة لـanon: **28 → 7**.
الـ7 الباقيين: دوال الطيار (3) · إعادة تعيين الباسورد (2 — بالتصميم) · وباقي بسيط.

---

## 🗑 حذف شاشة «تسوية وإغلاق» (`pos_reconciliation.html`) — 2026-08-30

**ليه:** مش مستخدمة — بديلها `shift_close.html` (الإغلاق) و`shift_history.html` (السجل والمطابقة). صلاحياتها كانت **للأدمن بس** وكل الأدوار التانية `can_view=false`.

**مفيش جدول اتحذف** — الشاشة ماكانتش بتلمس Supabase أصلًا. كانت بتستعمل webhooks n8n (`/webhook/posmanagement` و`/webhook/posupdate`)، **ودول نفسهم اللي `machine_import.html` بيستعملها** وهي شغّالة، فمفيش endpoint اتيتّم.

**اللي اتشال:**
1. الملف `pos_reconciliation.html` من الريبوهين (1560 سطر)
2. `delivery/app.html` — 3 مواضع: `ERP_PAGES` · `PAGE_META` · `NAV_ICONS`
3. `delivery/pages/permissions.html` — سطر خريطة الصفحة
4. `page_permissions` — 9 صفوف (SQL التراجع محفوظ في الميجريشن `remove_pos_reconciliation_page_permissions`)

**التحقق:** استخرجنا `ERP_PAGES`/`PAGE_META`/`NAV_ICONS` وقيّمناهم — كل صفحة لسه ليها عنوان وأيقونة، صفر أيقونات يتيمة، وصفر أثر للاسم. parse-check عدّى على الأربع ملفات. على الموقع الحي: الملف `404` و`app.html`/`permissions.html` بصفر إشارات.

> ⚠️ **درس:** `git add -A <مسار-محذوف> <مسارات-تانية>` بيفشل بالكامل والـcommit بيعدّي ناقص من غير ما يشتكي (خصوصًا مع `2>/dev/null`). النتيجة: أول commit خد ملف الصفحة بس وساب تسجيلها في القائمة. **راجع `git show --stat` بعد أي commit فيه حذف.**

> ملاحظة جانبية: `ERP_PAGES` متفرّعة بين الريبوهين (التست=37، البرودكشن=38 — البرودكشن فيه `expenses.html` زيادة). موجود من قبل التعديل ده.

---

## 🔧 الصلاحيات الافتراضية — 2026-08-30

### ⚠️ تصحيح لادعاء غلط
قلت في تقرير الحالة إن «أي جدول جديد بيتولد مكشوف بالكامل لـanon» بناءً على وجود إعداد `pg_default_acl` لدور `supabase_admin` بيدّي `anon=arwdDxtm`. **الاستنتاج ده كان غلط** — استنتجته من الإعداد من غير ما أختبر مين بيعمل الجداول فعلًا.

**الحقيقة (اتثبتت بجدول اختبار حقيقي اتعمل واتحذف):**
- كل الـ110 جدول في `public` مملوكة لـ**`postgres`**، وصفر مملوك لـ`supabase_admin`.
- الجدول الجديد بيخرج بـ`anon=Dxtm` = TRUNCATE + REFERENCES + TRIGGER فقط — **بلا أي قراءة أو كتابة**.
- يعني **مفيش نزيف مستمر**؛ الـ71 جدول المكشوفة أخدت صلاحياتها بمنح صريح في الماضي.
- إعداد `supabase_admin` كامن مش فعّال — وأنا (`postgres`) **مش عضو فيه فمقدرش أعدّله**. لو عايز حزام أمان إضافي، لازم يتعمل من لوحة Supabase.

### اللي اتطبّق
```sql
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
revoke truncate, trigger, references on all tables in schema public from anon, authenticated;
```
**النتيجة:** الجدول الجديد بقى `postgres` + `service_role` بس. و`TRUNCATE` اتشال من **101** جدول، و`TRIGGER`/`REFERENCES` من **110**.

**اتساب عن قصد:** `SELECT`/`INSERT`/`UPDATE`/`DELETE` (83 قراءة · 71 كتابة) — دي شغل المرحلة 2 جدول-جدول ومحتاجة تحويل الصفحات للتوكن الأول؛ سحبها دلوقتي بيكسر شاشات شغّالة.

**التحقق:** `ensure_integration_table` (الدالة الوحيدة اللي بتعمل جداول) بتفعّل RLS وبتمنح صلاحياتها **صراحةً**، فمش معتمدة على الافتراضيات. وبعد التطبيق: `medicine_orders` على الموقع الحي شغّالة (13,618 صنف · 100 صف) و`stores`/`purchase_orders_flat`/`stock_flat`/`get_stock_summary` كلهم رجّعوا 200.

### للتراجع
```sql
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated;
grant truncate, trigger, references on all tables in schema public to anon, authenticated;
```

> **الدرس:** `pg_default_acl` بيقول إيه *ممكن* يحصل لو دور معيّن عمل جدول — مش إيه اللي *بيحصل*. اختبر بجدول حقيقي قبل ما تبني استنتاج على إعداد.

---

# المرحلة 1 — نقل المصادقة لـSupabase Auth

## ✅ الجزء الأول: التمهيد وقاعدة البيانات — تمّ 2026-08-30 (صفر أثر على المستخدمين)

### 🎉 تصحيح جوهري لافتراض المستند
المستند كان بيقول: «هجّر المستخدمين، **أول دخول يعيد تعيين الباسورد لأن الهاش مايتقراش**». **ده غلط.**
`branch_users.password_hash` كله **bcrypt** (`$2a$06$` و`$2a$08$`) — ونفس اللي GoTrue بيستعمله. **اتأكدنا عمليًا** (حساب اختباري بـcost=8، نفس تكلفة الحسابات الحقيقية، ودخل بنجاح). يعني **الباسوردات اتنقلت زي ما هي ومحدش هيغيّر حاجة**.

### اللي اتعمل
| العنصر | التفاصيل |
|---|---|
| **80 حساب في `auth.users`** | من `branch_users` · الهاش منقول حرفيًا (اتأكدنا: 80/80 مطابق) · 80 صف في `auth.identities` |
| **الدور والفرع** | في `raw_app_meta_data`: `user_role`, `branch`, `branch_user_id`, `username` |
| **الحسابات الموقوفة** | 3 حسابات `is_active=false` → `banned_until='infinity'` فمش هيقدروا يدخلوا |
| **الإيميلات** | 16 حقيقي زي ما هو · 64 داخلي `u<id>@phalix.local` |
| **`resolve_login_email(text)`** | RPC بتحوّل اسم المستخدم/الموبايل/الإيميل → إيميل المصادقة. متاحة لـ`anon` (الدخول قبل المصادقة) · نشط فقط · أقل `id` لو الاسم مكرر |
| **`jwt_app_role()` و `jwt_branch()`** | بقوا **يقبلوا الشكلين**: المستوى الأعلى (n8n) ثم `app_metadata` (Supabase) |

### ⚠️ النقطة الحرجة: `jwt_app_role()` بتحرس 27 دالة + RLS بتاع `orders`
الترتيب `coalesce(المستوى_الأعلى, app_metadata)` معناه **سلوك توكنات n8n مايتغيّرش ولا حرف**. اتأكدنا بمصفوفة اختبار:

| السياق | n8n | Supabase | مطابق؟ |
|---|---|---|---|
| admin → guard | ✅ | ✅ | ✓ |
| driver → guard | ⛔ | ⛔ | ✓ |
| `orders` كـadmin | 20,626 صف | 20,626 صف | ✓ |
| `orders` كـemployee/المعمورة | 14,345 صف | 14,345 صف | ✓ |
| anon | 0 صف · ⛔ | — | ✓ |

### الاختبار النهائي بتوكن Supabase حقيقي عبر PostgREST
- `store_rename` (pharmacist مسموح) → عدّى الحراسة ووقع على `name_required` ✅
- `move_recon_txn` (pharmacist ممنوع) → **403 غير مصرّح** ✅
- `orders` → 200 ومحدود بالفرع ✅

### 🔎 ملاحظات لازمة للخطوة الجاية
1. **فك ترميز الـJWT في المتصفح:** `atob` لوحده **بيخرّب العربي** في `branch`. الصح:
   `JSON.parse(decodeURIComponent(escape(atob(payload))))`. الكود الحالي في `driver.html` و`app.html` بيستعمل `atob` مباشرة — يتراجع.
2. **مفيش `UNIQUE` على `branch_users.username`** — وفيه فعلًا **حسابان مكرران** لنفس الشخص (احمد عبدالله: `id 6` و`id 88`، نفس الدور والفرع، مش مربوطين بأي طيار). الاتنين اتعملهم حساب auth بإيميلات مختلفة، و`resolve_login_email` بتختار `id 6`. **يُفضّل حذف `id 88` وإضافة `unique(lower(username))`** — قرار بيانات محتاج موافقة.
3. **٥ أسماء مستخدمين عربية/فيها مسافات**: `المعمورة` · `سان ستيفانو` · `د على حسن على` · `د عماد الدين` · `يوسف ابراهيم احمد`. أول اتنين **حسابات فرع مشتركة** — بتخالف قاعدة «تسجيل مين عمل الإجراء لحساب شخص حقيقي».

## ⏳ الجزء الثاني: تحويل العملاء — لسه
1. `index.html` + `delivery/auth.html`: يجرّبوا Supabase Auth الأول (`resolve_login_email` ← `signInWithPassword`)، **وبرجوع تلقائي لـn8n لو فشل** — فمفيش لحظة قفل.
2. `checkAuth()` تعتمد على جلسة Supabase بدل `verify_token` webhook.
3. `api.js` / `supabase-config.js`: التوكن من الجلسة بدل `localStorage.authJwt`، **مع فحص انتهاء** (النمط اللي اتبع في 5 شاشات).
4. تطبيق الطيار (53 طيار): **يفضل على n8n** لحد ما APK جديد يتبني ويتوزّع. الدوال والسياسات بتقبل الشكلين فمفيش أي تعطل.
5. بعد ما الكل ينتقل: إيقاف webhooks الدخول/التحقق وسحب سرّ التوقيع من n8n.

## ✅ الجزء الثاني: تحويل صفحات الدخول — تمّ 2026-08-30

### التصميم: محاولة Supabase أولًا + رجوع تلقائي
`api.js` (يغطي `index.html`) و`delivery/auth.html` بيجرّبوا `resolve_login_email` ← `/auth/v1/token` الأول. **لو فشل لأي سبب → n8n زي ما هو.** فمفيش لحظة قفل، وتطبيق الطيار مالوش أي علاقة.

### ⚠️ فخ كان هيطلّع كل المستخدمين بعد ٣٠ دقيقة
`checkAuth()` بينده `verifyToken()` كل ٣٠ دقيقة، و`verifyToken()` كان بيبعت `authToken` لـ**webhook التحقق بتاع n8n**. توكن Supabase مش هيعرفه → `valid=false` → **`localStorage.clear()` + خروج**.
الحل: `verifyToken()` بقى يشوف `authProvider`؛ لو `supabase` بيتحقق من `exp` محليًا وبيجدد بالـ`refresh_token` بدل ما يضرب على n8n.

### ⚠️ `atob` بيخرّب العربي
`atob` لوحده بيرجّع اسم الفرع «المعمورة» رموز. الصح المستعمل في الكود:
`JSON.parse(decodeURIComponent(escape(atob(payload))))`

### اختبارات (بحساب اختباري حقيقي اتعمل واتحذف)
| # | الاختبار | النتيجة |
|---|---|---|
| 1 | `login()` بباسورد صح | ✅ · `authProvider=supabase` · الدور والفرع والاسم صح · **العربي سليم** |
| 2 | `verifyToken()` بجلسة صالحة | ✅ true بلا نداء n8n |
| 3 | `verifyToken()` بتوكن منتهي | ✅ اتجدد تلقائيًا لتوكن صالح والدور محفوظ |
| 4 | `login()` بباسورد غلط | ✅ رجع لـn8n · `authProvider` اتمسح · رسالة صحيحة |
| 5 | `auth.html` end-to-end | ✅ نفس النتائج (بدور `driver`) |

### ملاحظات نقل
- `api.js` **متفرّع فعليًا** بين الريبوهين (١٧٩ سطر فرق) — اتنقل **جراحيًا بالنص**. أول محاولة استعملت علامة بداية عامة (`// ===== `) فطابقت قسم تاني وكرّرت تعريفات؛ `node --check` مسكها. **استعمل علامة نصية فريدة.**
- الملفين CRLF في البرودكشن واتحافظ عليها.
- `auth.html` بتستعمل `SUPABASE_URL`/`SUPABASE_KEY` (من `supabase-config.js`) مش `SB_URL_API`/`SB_ANON_API`.

### ⏳ الباقي في المرحلة 1
1. `checkExistingSession()` في `auth.html` لسه بتضرب على webhook التحقق — لجلسة Supabase بترجّع false فبتطلب دخول من جديد (مش خروج، بس مزعج). يستاهل نفس معالجة `verifyToken`.
2. `supabase-config.js` بياخد `authJwt` وقت التحميل بلا فحص انتهاء — لو التوكن انتهى، كل نداءات الصفحة تبقى 401. يتنقل لنمط فحص `exp`.
3. **تطبيق الطيار**: APK جديد بمصادقة Supabase + توزيعه على ٥٣ طيار.
4. بعد ما الكل ينتقل: إيقاف webhooks `login`/`verify_token` وسحب سرّ التوقيع من n8n.

### ✅ الدخول بالموبايل: مافيش أي تغيير للمستخدم
`resolve_login_email` بتطابق **اسم المستخدم أو الموبايل أو الإيميل**. اتأكدنا على كل الـ77 حساب النشط: **صفر فشل** في التحويل بالتلاتة.
- **64 حساب** اسم المستخدم فيهم = رقم الموبايل → بيكتبوا الرقم زي ما هما بيعملوا بالظبط.
- **7 حسابات** الموبايل مختلف عن اسم المستخدم → **الاتنين بيشتغلوا دلوقتي** (أوسع شوية من قبل، لكن الباسورد لسه مطلوب).
- **6 حسابات** بلا موبايل → باسم المستخدم بس، زي الأول.

### 🔴 حالة واحدة محتاجة قرار: «احمد عبدالله»
الحسابان المكرران (`id 6` و`id 88`, نفس الاسم/الدور/الفرع) **ليهم باسوردين مختلفين**.
`resolve_login_email` بتختار `id 6` (الأقدم). لو الباسورد الشغّال بتاعه هو اللي على `id 88`:
- Supabase هيرفض → **بيرجع تلقائيًا لـn8n ويدخل عادي** (مفيش تعطل)
- بس هو **مش هينتقل للنظام الجديد أبدًا**
**المطلوب:** تحديد أي الحسابين هو الحقيقي، حذف التاني، وإضافة `unique (lower(username))` عشان ما يتكررش تاني.

### 🐞 خطأ اتصلح: الدخول كان لسه بيروح على n8n بسبب الكاش
بعد نشر تعديل المصادقة، أول دخول حقيقي **عدّى على n8n مش Supabase**. اتأكدنا من السيرفر: `auth.sessions` = **صفر** و`last_sign_in_at` = null لكل الحسابات.

**السبب:** `api.js` اتعدّل لكن الصفحات كانت لسه بتطلبه بـ`?v=tt20260824d` — **نفس الرابط القديم** → المتصفح جابه من الكاش (النسخة القديمة بلا `sbAuthLogin`) → `login()` راحت على n8n مباشرة.

**دي بالظبط القاعدة رقم 6 في CLAUDE.md** (cache-busting) وأنا نسيتها. الرقم اتوحّد على `tt20260830` في الـ34 صفحة (كانت 3 أرقام مختلفة: `tt20260824d`×31, `tt20260826`×2, `tt20260828`×1).

> **للمرة الجاية:** أي تعديل في `api.js` أو أي JS مشترك **لازم** يتبعه رفع `?v=`. وطريقة التأكد إن المسار الجديد اشتغل فعلًا مش من الكود — من `auth.sessions` و`last_sign_in_at`.

### 🐞 عيب تصميمي اتصلح: النسخة كانت بتتفكّ عن الأصل
أول دخول حقيقي بعد رفع رقم الإصدار وصل لـSupabase فعلًا (`POST /auth/v1/token` في الكونسول) لكن رجّع **400** ورجع لـn8n.

**السبب:** التمهيد نسخ `password_hash` و`email` من `branch_users` لـ`auth.users` **مرة واحدة**. أي تعديل بعدها في `branch_users` (تغيير باسورد، إضافة إيميل، إيقاف حساب) مابيوصلش لـ`auth.users` → الدخول عبر Supabase يفشل بصمت ويرجع لـn8n.
حصل فعليًا مع `id=4` (حساب الأدمن): **الهاش والإيميل الاتنين** كانوا اتغيّروا بعد التمهيد.

**الحل — مزامنة تلقائية بدل نسخة ساكنة:**
- `sync_branch_user_to_auth()` + تريجر `AFTER INSERT OR UPDATE OF username, password_hash, email, role, branch, is_active, full_name, legacy_id` على `branch_users`. بينشئ حساب auth للصفوف الجديدة وبيحدّث الموجودة (هاش · إيميل · `app_metadata` · `banned_until`).
- `resolve_login_email` بقت **تقرا الإيميل من `auth.users` مباشرة** بدل ما تعيد حساب نفس القاعدة → مصدر واحد، استحالة انحراف.
- إعادة مزامنة شاملة: **80/80 متطابقين** في الهاش والإيميل والدور والحالة.

**اختبار التريجر (اتعمل واتراجع):** إضافة مستخدم جديد → اتعمله حساب auth تلقائيًا بهاش مطابق ✅ · تغيير الباسورد → اتزامن لوحده ✅

> **الدرس:** أي هجرة بتنسخ بيانات حيّة لازم يبقى معاها مزامنة، وإلا بتتفكّ من أول تعديل. والاعتماد على الرجوع التلقائي بيخفي الفشل — الفشل ماظهرش غير لما بصينا على `auth.sessions` وطلعت صفر.

### 🔥 انقطاع سببه الإصلاح نفسه — 2026-08-31 (اتصلح)
بعد نشر تجديد التوكن، **شاشة التوزيع بقت فاضية للأدمن والكاشير**: مفيش فروع ولا طلبات ولا طيارين. تلات أخطاء متراكبة في `delivery/supabase-config.js`:

1. الـ`fetch` المخصص كان بيعمل `{...options.headers}` — و`supabase-js` بيبعتها **`Headers` instance**، والنشر عليها بيدّي `{}` فالـ`apikey` يضيع → `No API key found in request`. الصح `new Headers(options.headers)`.
2. بعد إصلاح (1): الرجوع لمفتاح `anon` لما التوكن منتهي **مش كفاية** — سياسة `orders` بتدّي `anon` **صفر صفوف**، فالشاشة تفضل فاضية **من غير أي رسالة خطأ**. الفشل الصامت ده هو اللي خلّى التشخيص صعب.
3. `sbRefreshSession()` كانت بتتنده من غير `await` وقت تحميل الملف → الاستعلامات بتطلع قبل ما التجديد يخلص.

**الإصلاح:** الـ`fetch` بقى `async` — لو التوكن منتهي **يستنى التجديد يخلص** وبعدين يبعت الطلب بالتوكن الجديد؛ وتجديد واحد بس مهما كان عدد النداءات المتوازية (`_sbRefreshInFlight`) عشان الـrefresh token ما يتحرقش. والتوكن اتشال من الهيدر الثابت خالص (كان بيتاخد وقت التحميل ويفضل يتبعت بعد ما ينتهي).

**اتأكد شغّال:** المالك أكّد الشاشة رجعت. واختبار محلي بحساب أدمن حقيقي بتوكن منتهي: 4 تابات فروع · 1000 طلب · 12 طيار · والتوكن اتجدد لوحده.

> **الدرس (اتسجّل كقاعدة دائمة):** اختبار الدالة ≠ اختبار الشاشة. لازم تُفتح الشاشة المتأثرة نفسها قبل النشر. راجع `[[test-before-publishing]]`.

---

## مراجعة المعمارية — الخطوة 3: وحدة الجلسة (session.js)  ✅ 2026-09-04

**الملف الجديد:** `session.js` (جذر المشروع، بيتحمّل بعد `config.js` مباشرة في 54 صفحة)

### ثغرة أمنية اتقفلت
`logout()` في الشل (`delivery/app.html`) وفي `delivery/permissions.js` كان بيمسح
مفاتيح الجلسة **بالاسم** وناسي:
- `authJwt` — توكن الوصول
- `sbRefresh` — **الـrefresh token** (بيقدر يولّد توكنات جديدة)
- `authProvider` — اللي بيخلّي التجديد التلقائي يشتغل

النتيجة: بعد ما المستخدم «يخرج»، الجهاز يفضل شايل جلسة قابلة للتجديد،
و`setInterval` بتاع التجديد يفضل يشتغل. على أجهزة مشتركة (الكاشير،
تليفونات السواقين) = اللي بعده يقدر يكمل بجلسة اللي قبله.
وقت الاكتشاف كان فيه **136 refresh token صالح** في `auth.refresh_tokens`.

**الحل:** `Session.KEYS` قائمة واحدة بالـ13 مفتاح، و`Session.clear()` بيمسحها كلها.

### تجديد التوكن: 5 تنفيذات → 1
كان مكرر في `api.js` و`delivery/app.html` و`delivery/auth.html` و
`delivery/supabase-config.js` و`shift_history.html` — **تلاتة منهم من غير قفل**.
Supabase بيحرق الـrefresh token مع كل استعمال، فسياقين بيجدّدوا في نفس اللحظة
= واحد ياخد «Already Used» = «خطأ في التحميل» اللي كان بيقطع الشغل.

`Session.refresh()` فيه تلات طبقات حماية: تجميع النداءات في الصفحة (`_inFlight`)،
قفل `navigator.locks` على مستوى الأصل كله، وإعادة فحص التوكن جوّه القفل.
**اتأكدت بالتجربة: 8 نداءات متوازية = طلب شبكة واحد.**

### باجات اتصلحت في الطريق
| الباج | الأثر | الحل |
|---|---|---|
| `manger` (غلطة إملائية) | صفحة واحدة بس (`customers.html`) كانت بتتعامل معاها — نفس المدير يعدّي في شاشة ويتمنع في شاشة | `Session.normRole()` بيطبّع مركزيًا |
| مفتاح `userName` بيتقرا في 3 أماكن ومابيتكتبش أبدًا | «مين عمل الإجراء» بيقع على اسم الفرع — `task_done.done_by` متسجّل «كل الفروع» | `Session.fullName()` (قاعدة الإسناد للشخص الحقيقي) |
| `localStorage.clear()` عند الخروج | بيمسح التفضيلات كمان (الثيم، حجم الخط، عرض الأعمدة) | `Session.clear()` بيمسح الجلسة بس |
| `userBranch = branch \|\| username` | اسم المستخدم بيتعامل كفرع فالفلترة ترجّع فاضي | `Session.save()` مابيرجعش لاسم المستخدم؛ اللي عايز كده يبعته صريح |

### واجهة الوحدة
```
Session.user() / role() / branch() / branchId() / username() / fullName()
Session.is('admin','manager') / isAdmin()
Session.save(result) / resolveBranchId()
Session.refresh(marginMs) / validToken() / tokenValid(marginMs)
Session.can('expenses.html') → {view, edit}   // من get_role_pages، مكاش
Session.require({roles, page}) / clear() / logout()
```

### الأدوار
اتحاد `branch_users` و`page_permissions` — الجدولين **مش متطابقين**:
- `supervisor` → له 53 صف صلاحيات لكن **صفر مستخدم**
- `driver` → **54 مستخدم** لكن صفر صفوف صلاحيات

دور مش في القائمة بيعدّي زي ما هو (مش بيتحوّل لـemployee) عشان أي دور جديد
مايتمنحش صلاحيات بالغلط.

### التحقق قبل النشر
- 54 صفحة اتفحصت في المتصفح على الريبوهين (تحميل + Session + مفيش أخطاء JS)
- parse-check: 55 صفحة صفر أخطاء (الريبوهين)
- اختبار وظيفي: `store_prices` جابت ٤٩٬٠٢٨ صنف، `shortages` فلترت على الفرع،
  `dispatch` حلّت `branch_id` الحقيقي من القاعدة
- الموقع الحيّ اتأكد بعد النشر

### باقي من المراجعة
4. الفروع من قاعدة البيانات بدل مصفوفات مكتوبة في الصفحات
5. صلاحيات بأسماء واضحة بدل أسماء ملفات
6. `branch_id` بدل اسم الفرع كنص
7. ألوان بـtokens بدل قيم صريحة

---

## مراجعة المعمارية — الخطوة 4: الفروع من قاعدة البيانات  ✅ 2026-09-04

**ملفات جديدة:** `branches.js` (وحدة الفروع) و`brand.js` (محمّل الهوية)

### تغيير قاعدة البيانات
```sql
alter table branches add column code text;            -- mamora / san / bishr
alter table branches add column aliases text[];       -- أسماء المخازن والتهجئات البديلة
alter table branches add column sort_order int;
alter table branches add column is_active boolean not null default true;
alter table branches add column phone text;           -- الشاشة كانت بتبعته وهو مش موجود
create unique index branches_code_uniq on branches (code) where code is not null;
create unique index branches_name_uniq on branches (name);
```
**اتطبّق على السحابة والسيرفر الجديد الاتنين.**

القيم الحالية:
| الاسم | code | aliases |
|---|---|---|
| المعمورة | `mamora` | الصيدلية |
| سان ستيفانو | `san` | ابراهيم حمدي 2، سان |
| سيدى بشر | `bishr` | ابراهيم حمدي 3، سيدي بشر |

### اللي اتشال من الكود
الفروع كانت مكتوبة صريح بأربع صور: قائمة أسماء، خريطة كود→اسم،
خريطة اسم→اسم المخزن، وقايمة UUIDs في شاشة التوزيع — في ~20 ملف.

### واجهة الوحدة
```
Branches.all() / names() / codes() / ids()
Branches.byName() / byCode() / byId()
Branches.toName(v)   // اسم أو كود أو اسم مخزن أو uuid → الاسم القياسي
Branches.toCode(v) / toId(v) / storeName(v)
Branches.codeMap() / storeMap() / aliasMap()
Branches.fillSelect(el, {all, value}) / autofill()
Branches.load(force) / ready() / onChange(fn)
```

**ملء تلقائي تصريحي:** `<select data-branches>` بيتملى لوحده.
`data-branches="code"` للكود، `="store"` لاسم المخزن، `="id"` للـuuid.
الخيارات اللي مش فروع تفضل في الـHTML؛ اللي عايز يفضل آخر القايمة
(زي «عام») ياخد `data-after`.

**اختبار حاسم:** ضفت فرع رابع للقاعدة → ظهر في الـ15 قايمة كلها من غير
تعديل سطر واحد، وبعدين اتشال.

### باجات اتصلحت
| الباج | الأثر |
|---|---|
| `inventory_min` بتفلتر بـ«سيدي بشر» والبيانات «سيدى بشر» | الفرع كان بيعرض **٠ من ١٨ صف** |
| شاشة «الفروع» بتبعت عمود `phone` غير موجود | **كل حفظ بيرجع 400** والنافذة تتقفل كأنه نجح |
| محررين مختلفين للفروع (جدول `branches` مقابل `org_settings.branches` jsonb) | مضمون يتفرّعوا |
| حذف فرع عليه بيانات بيفشل بصمت | بقى برسالة واضحة (10 مفاتيح أجنبية بتمنع الحذف) |

### مصدر التحرير الوحيد
شاشة **«الفروع»** في تطبيق التوصيل = المحرر الوحيد (اتضاف لها حقلَي
الكود والأسماء البديلة). **«إعدادات المؤسسة»** بقت عرض فقط للفروع،
ومابقتش تكتب `org_settings.branches`.

### دَين متبقّي (مش في نطاق الخطوة دي)
- **أعمدة قاعدة البيانات لكل فرع**: `balance_san`، `surplus_mamora`،
  `m_q/s_q/b_q`، `av_mamora`، `customer_san_search` — دي أعمدة فعلية
  في الجداول، يعني **فرع رابع لسه محتاج تعديل schema** مش بس كود.
  الحل الصح صفوف بدل أعمدة، وده ترحيل بيانات كبير.
- `LEGACY_USER_BRANCH` (`mangersan`/`mangermamora`…) مكررة في 3 صفحات —
  دي أسماء مستخدمين قديمة مش فروع، شأن تاني.
- رؤوس الجداول (`<th>`) المرتبطة بالأعمدة دي لسه ثابتة.

### التحقق قبل النشر
- 54 صفحة في المتصفح على الريبوهين | parse-check 55 صفحة صفر أخطاء
- `inventory_min` بقت تعرض 18 صف لسيدى بشر (كانت صفر)
- `salesanalysis` و`inventory_management` أعطوا نفس القيم القديمة بالظبط
- الموقع الحيّ اتأكد بعد النشر

### باقي من المراجعة
5. صلاحيات بأسماء واضحة بدل أسماء ملفات
6. `branch_id` بدل اسم الفرع كنص
7. ألوان بـtokens بدل قيم صريحة

---

## مراجعة المعمارية — الخطوة 5: صلاحيات بأسماء ثابتة  ✅ 2026-09-04

**ملف جديد:** `pages.js` (كتالوج الشاشات)

### المشكلة
كتالوج الشاشات (الاسم المعروض والمجموعة) كان مكتوب **مرتين** في الكود —
`delivery/app.html` للقائمة و`delivery/pages/permissions.html` لشاشة
الصلاحيات — وكانوا **مختلفين في 42 موضع**:

| | القائمة | شاشة الصلاحيات |
|---|---|---|
| `customer_problems` | «تعليمات عامة» / الإدارة والنظام | «مشاكل العملاء» / الصيدلية |
| عدد المجموعات | 9 | 4 |
| شاشات مفقودة | — | **4** (المصروفات، الربط بالمصادر، أسعار الزيوت، أرصدة نقاط البيع) |

الشاشات الأربعة دي مكانتش ظاهرة في شاشة الصلاحيات خالص — يعني الأدمن
**ماكانش يقدر يديها لأي دور**.

وأخطر من كده: الصلاحيات كانت مربوطة **باسم الملف**، فتغيير اسم ملف =
ضياع صلاحياته بصمت.

### تغيير قاعدة البيانات
```sql
create table app_pages (
  key text primary key,      -- 'shift_close'  ← الاسم الثابت
  file text not null unique,  -- 'shift_close.html'
  title text not null,        -- 'إغلاق الشيفت'
  section text not null,      -- 'الحسابات والخزينة'
  sort_order int, badge text, is_active boolean default true
);
alter table page_permissions add column page_key text;   -- + trigger يخلّيه متسق مع page
```
`get_role_pages()` بقت ترجّع `key` و`title` و`section` و`badge` مع الصلاحية.
`save_page_permissions_bulk()` بتقبل `page_key` أو `page`.
**اتطبّق على السحابة والسيرفر الجديد الاتنين.**

### تنظيف البيانات
- 4 صفوف يتيمة اتشالت: `jard_list.html` / `operations.html` /
  `overview.html` / `pos_close.html` — مفيش ليها ملفات ولا أي إشارة في الكود.
- الشاشات الناقصة أدوار اتكمّلت بـ**منع صريح** (نفس السلوك الحالي بالظبط)
  عشان تبان وتتعدّل → **51 شاشة × 9 أدوار = 459 صف كاملة**.

### التحقق قبل النشر
- **مفيش صلاحية ضاعت**: كل دور بيرجّع نفس عدد الصفحات قبل وبعد
  (admin 51، manager 37، employee 26، pharmacist 14، accountant 10،
  reviewer 9، supervisor 6، cashier 5، inventory 3)
- **اختبار حاسم**: غيّرت اسم شاشة في `app_pages` → اتغيّر في القائمة
  وشاشة الصلاحيات مع بعض، وبعدين رجّعته.
- شاشة الصلاحيات بتعرض 51 شاشة في 9 مجموعات، و459 قائمة في وضع التعديل،
  وقيمها بقت مفاتيح ثابتة مش أسماء ملفات.
- 54 صفحة في المتصفح على الريبوهين | parse-check 55 صفحة صفر أخطاء
- الموقع الحيّ اتأكد بعد النشر

### ملاحظة
جدول `app_pages` مفتوح للقراءة للكل (`policy ... using (true)`) — ده
كتالوج أسماء شاشات، مفيش فيه بيانات حساسة. الكتابة عليه **مش** متاحة
لـanon (مفيش policy للكتابة)، فالتعديل بيتعمل من قاعدة البيانات مباشرة
لحد ما نعمل له شاشة إدارة.

### باقي من المراجعة
6. `branch_id` بدل اسم الفرع كنص
7. ألوان بـtokens بدل قيم صريحة

---

## مراجعة المعمارية — الخطوة 6: أمان الفرع  ✅ 2026-09-04

### قرار النطاق — ليه مانقلناش الـ45 جدول لـbranch_id

الخطة الأصلية كانت ترحيل كل عمود `branch` نصي لـ`branch_id`. فحصت
البيانات الأول بدل ما أفترض:

| | | |
|---|---|---|
| صفوف بقيمة فرع **مش مفهومة** | **54** | كلها أسماء مستخدمين في `task` |
| `عام` / `كل الفروع` | 62 | نطاقات **مقصودة** مش فروع |
| `price_changes` (3925 صف بأكواد) | ✅ سليمة | الكود اتسجّل في `branches.code` |
| `store` في جداول الأسعار | خارج النطاق | **موردين** (الابرار، تارجت، عابدين) مش فروع |

يعني البيانات نضيفة. والترحيل كان هيكسر:
- مزامنة n8n اللي بتكتب الجداول دي **بالاسم**
- كل الـRPCs والتقارير اللي بتفلتر بالاسم
- ~100 موضع في الواجهة

**مخاطرة كبيرة مقابل مكسب صفر في جودة البيانات** → اتعمل الحل اللي
بيدّي نفس النتيجة العملية.

### الخطر الحقيقي اللي اتقفل
بعد ما زرار حفظ الفروع اتصلح في الخطوة 4، إعادة تسمية فرع واحد بقت
**تيتّم 121,278 صف في 36 جدول** بصمت.

**الحل:** trigger على `branches` بيسرّي إعادة التسمية على كل أعمدة الفرع
النصية في **معاملة واحدة** — الاسم والكود واسم المخزن.

**اتجرّب فعليًا على البيانات الحقيقية:**
| التغيير | صفوف اتحدّثت | جداول | صفوف يتيمة |
|---|---|---|---|
| اسم «المعمورة» | **48,213** | 31 | **0** |
| اسم المخزن «الصيدلية» | **66,930** | 1 | **0** |
| الرجوع للأصل | 48,213 | 31 | **0** |

`branch_rename_log` بيسجّل كل عملية.

### دوال القاعدة
```sql
branch_name(text)        -- أي شكل → الاسم القياسي
branch_id(text)          -- أي شكل → uuid
branch_store_name(text)  -- أي شكل → اسم المخزن في eplus
```

### كشف الانحراف
`v_branch_value_audit` بيعدّي على كل أعمدة الفرع النصية ويرجّع أي قيمة
مش قابلة للتحويل (بعد استبعاد النطاقات في `branch_scope_values`).
**ده اللي كان هيلقط باج inventory_min** من غير ما نكتشفه بالصدفة.
ظاهر في «إعدادات المؤسسة» — **للمسجّلين بس، مش anon**.

### الواجهة
`Branches.same(a,b)` بتقارن فرعين مهما كان شكل كل واحد. اتطبّقت في **13
مقارنة** بتقارن بيانات مخزّنة بفرع المستخدم (missing_items، inventory،
contracts، supplier_balances، reports، pos_methods، shortages ×2،
transfers ×3، customers ×2).

**اتأكدت:** «سيدى بشر» و«سيدي بشر» و«bishr» و«ابراهيم حمدي 3» كلهم
بيرجّعوا **نفس الـ53 صف** — قبل التصليح التلاتة الأخيرة كانوا صفر.

### دَين متبقّي
- **54 صف في `task.branch`** فيها أسماء مستخدمين بدل فروع — دي مشكلة
  `task.user` المعروفة، بتتعالج في الواجهة بـ`branchOf()`. الأنضف
  تصليحها في المصدر (n8n).
- **أعمدة لكل فرع** (`balance_san`، `m_q/s_q/b_q`، `av_mamora`…) لسه
  موجودة — فرع رابع حقيقي محتاج تعديل schema. (من الخطوة 4.)

### باقي من المراجعة
7. ألوان بـtokens بدل قيم صريحة
