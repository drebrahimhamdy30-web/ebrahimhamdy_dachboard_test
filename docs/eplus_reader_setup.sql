/* ============================================================
   إعادة إنشاء حساب القراءة فقط (phalix_reader) على eplus
   بعد تسطيب SQL Server جديد أو استعادة قاعدة من نسخة.
   ------------------------------------------------------------
   ⚠️ سيرفرات الفروع = SQL Server 2000. الصيغة هنا 2000
      (sp_addlogin ... مش CREATE LOGIN/sys.server_principals بتوع 2005+).

   السبب: تسطيب SQL جديد بيمسح master (وفيها التسجيلات)، واستعادة
   القاعدة بتخلّي المستخدم جوّه Genius «يتيم» (SID قديم). العرض:
   «Login failed» أو بعد الإنشاء «SELECT permission denied» رغم db_datareader.

   ⚠️ كلمة السر لازم = نفس الموجودة في:
      C:\ProgramData\phalix\sync_engine.json (جهاز المعمورة)
      المفتاح branches.<الفرع>.password — انسخها زي ما هي.

   ───────────────────────────────────────────────────────────
   التشغيل:
   (أ) لو عندك حساب sysadmin (sa أو حساب ويندوز سيسأدمن):
       افتح Query Analyzer (isqlw.exe) → اتصل → الصق ده وشغّل F5.
       أو: osql -S . -U sa -P <sa> -i eplus_reader_setup.sql

   (ب) لو مفيش sysadmin معروف (sa مجهول، وحساب الويندوز مش sysadmin):
       شغّل osql بحساب NT AUTHORITY\SYSTEM (sysadmin على SQL 2000)
       عبر مهمة مجدولة مؤقتة من PowerShell بحساب أدمن ويندوز:
         schtasks /create /tn pfix /tr "<bat يشغّل osql -S . -E -i هذا_الملف>" ^
                  /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f
         schtasks /run /tn pfix   &&   schtasks /delete /tn pfix /f
   ============================================================ */

/* (0) فحص: السيرفر بيسمح بتسجيل دخول SQL؟ لو رجّع 1 = Windows-only،
      حوّله Mixed Mode (Enterprise Manager → Properties → Security) + ريستارت. */
SELECT CONVERT(int, SERVERPROPERTY('IsIntegratedSecurityOnly')) AS windows_only_1_yes,
       @@VERSION AS sql_version
GO

/* (1) التسجيل (master) — صيغة SQL 2000 */
USE master
GO
IF NOT EXISTS (SELECT 1 FROM syslogins WHERE name = 'phalix_reader')
  EXEC sp_addlogin 'phalix_reader', '<<ضع_نفس_كلمة_السر_من_sync_engine.json>>', 'Genius'
ELSE
  EXEC sp_password NULL, '<<ضع_نفس_كلمة_السر_من_sync_engine.json>>', 'phalix_reader'
GO

/* (2) ⭐ إصلاح المستخدم «اليتيم» جوّه Genius — المفتاح لو القاعدة مستعادة.
      بيربط مستخدم phalix_reader الموجود بالتسجيل الجديد (SID). */
USE Genius
GO
IF EXISTS (SELECT 1 FROM sysusers WHERE name = 'phalix_reader' AND issqluser = 1)
  EXEC sp_change_users_login 'Update_One', 'phalix_reader', 'phalix_reader'
ELSE
  EXEC sp_grantdbaccess 'phalix_reader'   -- مش موجود أصلًا: أنشئ المستخدم
GO

/* (3) قراءة فقط على كل الجداول */
EXEC sp_addrolemember 'db_datareader', 'phalix_reader'
GO

/* (4) تأكيد: لازم ترجّع صفوف من جداول المزامنة */
SELECT 'Vendor' t, COUNT(*) n FROM Vendor
UNION ALL SELECT 'pur_trans_h', COUNT(*) FROM pur_trans_h
UNION ALL SELECT 'Item_back_h', COUNT(*) FROM Item_back_h
UNION ALL SELECT 'Store',       COUNT(*) FROM Store
UNION ALL SELECT 'Employee',    COUNT(*) FROM Employee
GO

/* (5) ⚠️ أهم رقم: أعلى فاتورة شراء. المزامنة بتجيب «الأجدد من المؤشّر
      المخزّن». لو ده أقل من المؤشّر (بسبب استعادة نسخة أقدم) الفواتير
      الجديدة مش هتوصل أبدًا بصمت — ساعتها صفّر المؤشّر («سحب فترة»). */
SELECT (SELECT MAX(pth_id) FROM pur_trans_h) AS max_purchase_id,
       (SELECT MAX(ibh_id) FROM Item_back_h) AS max_return_id
GO

/* (6) تأكيد نهائي من برّه — لازم يرجّع رقم:
      osql -S . -U phalix_reader -P <pw> -d Genius -Q "SELECT MAX(pth_id) FROM pur_trans_h" */
