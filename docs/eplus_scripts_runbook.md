# دليل تشغيل سكربتات eplus / Supabase (قراءة وكتابة)

الهدف: أى سكربت قراءة أو كتابة يشتغل **من أول مرة** بمسار واضح، بدون تجربة وخطأ.

## 1) المكان الثابت (مرة واحدة على الماستر)

نسخة محلية من الريبو — مش تنزيل على سطح المكتب:

```powershell
git clone https://github.com/drebrahimhamdy30-web/ebrahimhamdy_dachboard.git C:\phalix\dashboard
```

كل السكربتات فى `C:\phalix\dashboard\scripts\`. الأسرار (مفاتيح/باسوورد مشفّر) فى `C:\phalix\` **برّه** الريبو.

## 2) الطريقة القياسية لأى تشغيل

```powershell
cd C:\phalix\dashboard
git pull
.\scripts\<اسم_السكربت>.ps1        # قراءة/عرض افتراضيًا
.\scripts\<اسم_السكربت>.ps1 -Apply  # للكتابة (السكربتات الكاتبة عرض افتراضى + -Apply للتنفيذ)
```

لا تنزيل مباشر (`Invoke-WebRequest`) — بيكاش نسخة قديمة. النسخة المحلية + `git pull` هى المصدر.

## 3) القواعد الإلزامية لأى سكربت جديد (القوالب بتطبّقها)

1. **الترميز:** احفظ الملف **UTF-8 with BOM**، وإلا PowerShell 5.1 يقرا العربى ANSI ويكسر الصيغة.
2. **الباسوورد:** `SecureString` (Read-Host -AsSecureString) أو ملف مشفّر — **ممنوع** أى سر مكتوب فى الملف (الريبو عام).
3. **قراءة Supabase:** `Invoke-WebRequest … -UseBasicParsing` ثم `ConvertFrom-Json` — **مش** `Invoke-RestMethod` (بيفسّر JSON غلط على PS القديم بالماستر).
4. **كتابة Supabase:** الـbody **بايتات UTF-8** (`[Text.Encoding]::UTF8.GetBytes($json)`) + `Content-Type: application/json; charset=utf-8`، وإلا العربى يبقى `?`.
5. **ممنوع عربى فى رابط PostgREST** (الفلتر) — اعمل **دالة RPC** تفلتر على السيرفر وناديها بـPOST.
6. **أى جدول Supabase جديد:** `grant … to authenticated` (للشاشة) + `grant all … to service_role` (للسكربت)، وإلا 403.
7. **SQL Server 2000 (eplus):** استعلامات **parameterized** (`AddWithValue`) — العناوين/الأسماء فيها علامات. صيغة 2000 (مفيش ميزات أحدث). المنح للـwriter عبر مهمة **SYSTEM** مؤقتة.
8. **الكتابة على eplus:** عرض افتراضى (preview)، `-Apply` للتنفيذ، واكتب **بشرط أمان** (مثلاً «القيمة لسه فاضية») عشان ما تخربش بيانات موجودة.
9. **رد REST فاضى:** `@()` بتعمل عنصر `$null` وهمى → فلتر `| Where-Object { $_ }`.
10. **قبل الدفع:** parse-check بـ`[System.Management.Automation.Language.Parser]::ParseFile`، وجرّب على عيّنة.

## 4) القوالب الجاهزة (انسخ منها)

- **قراءة/اكتشاف:** `scripts/discover_delivery_rows.ps1` — اتصال eplus + استعلام + طباعة.
- **قراءة+كتابة Supabase↔eplus:** `scripts/region_writeback.ps1` — كل القواعد فوق مطبّقة (IWR+ConvertFrom-Json، UTF-8، RPC، parameterized، أوضاع، باسوورد مشفّر).
- **منح صلاحيات على eplus:** `scripts/grant_region_writer_system.ps1` — مهمة SYSTEM مؤقتة + osql.
- **جدولة مهام:** `scripts/setup_region_tasks.ps1` — AES + schtasks كـSYSTEM.

## 5) الأسرار على الماستر

- `SUPABASE_SERVICE_KEY` → متغيّر بيئة للجهاز (للمهام) أو للجلسة.
- باسوورد `phalix_writer` → ملف مشفّر AES فى `C:\phalix\rw.sec` + مفتاح `C:\phalix\rw.key` (صلاحيات SYSTEM/Administrators فقط).
- ولا سر منهم فى الريبو إطلاقًا.
