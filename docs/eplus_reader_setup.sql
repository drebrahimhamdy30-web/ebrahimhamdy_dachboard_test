/* ============================================================
   إعادة إنشاء حساب القراءة فقط على eplus بعد تسطيب SQL Server جديد
   ------------------------------------------------------------
   يُنفَّذ على سيرفر SQL الخاص بالفرع نفسه (SSMS → New Query)
   بحساب sysadmin (sa أو حساب ويندوز أدمن)، وقاعدة التنفيذ master.

   السبب: تسطيب SQL Server جديد بيمسح قاعدة master، ومعاها كل
   تسجيلات الدخول — ومنها phalix_reader. المزامنة ساعتها بتوصل
   للسيرفر وبيرفض الدخول («Login failed for user 'phalix_reader'»).

   ⚠️ الحساب ده للقراءة فقط. ممنوع أي صلاحية كتابة على Genius —
   نظام البيع مابيتكتبش فيه من برّه أبدًا.

   ⚠️ كلمة السر لازم تكون **نفس** الموجودة في ملف إعدادات المزامنة
   على جهاز المعمورة: C:\ProgramData\phalix\sync_engine.json
   (المفتاح branches.<الفرع>.password). لو حطيت كلمة سر جديدة،
   لازم تعدّل الملف ده كمان وإلا المزامنة تفضل واقفة.
   ============================================================ */

/* (0) فحص: هل السيرفر بيسمح بتسجيل دخول SQL أصلًا؟
      لو رجّع 1 يعني «Windows Authentication only» — لازم تتحوّل
      لـMixed Mode من خصائص السيرفر:
      SSMS → right-click السيرفر → Properties → Security →
      «SQL Server and Windows Authentication mode» → ثم إعادة
      تشغيل خدمة SQL Server (الإعداد مابيسريش غير بعد الريستارت). */
SELECT SERVERPROPERTY('IsIntegratedSecurityOnly') AS windows_only_1_yes,
       @@VERSION AS sql_version;
GO

/* (1) تسجيل الدخول */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'phalix_reader')
BEGIN
  CREATE LOGIN [phalix_reader]
    WITH PASSWORD = N'<<ضع_نفس_كلمة_السر_من_sync_engine.json>>',
         DEFAULT_DATABASE = [Genius],
         CHECK_POLICY = OFF,      -- عشان ماتنتهيش صلاحيتها وتوقف المزامنة
         CHECK_EXPIRATION = OFF;
  PRINT 'تم إنشاء تسجيل الدخول phalix_reader';
END
ELSE
BEGIN
  /* موجود بالفعل: نضبط كلمة السر ونلغي انتهاء الصلاحية */
  ALTER LOGIN [phalix_reader]
    WITH PASSWORD = N'<<ضع_نفس_كلمة_السر_من_sync_engine.json>>',
         CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
  ALTER LOGIN [phalix_reader] ENABLE;
  PRINT 'تم تحديث تسجيل الدخول الموجود';
END
GO

/* (2) المستخدم جوّه قاعدة Genius
      لو القاعدة مستعادة من نسخة احتياطية، المستخدم بيبقى موجود
      لكن «يتيم» (SID بتاع سيرفر قديم) — ALTER USER بتربطه بالجديد. */
USE [Genius];
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'phalix_reader')
  ALTER USER [phalix_reader] WITH LOGIN = [phalix_reader];   -- إصلاح اليتيم
ELSE
  CREATE USER [phalix_reader] FOR LOGIN [phalix_reader];
GO

/* (3) قراءة فقط — ومنع الكتابة صريح مش بالاعتماد على غياب الصلاحية */
EXEC sp_addrolemember N'db_datareader', N'phalix_reader';   -- شغّالة على كل الإصدارات
GO
DENY INSERT, UPDATE, DELETE, ALTER, EXECUTE TO [phalix_reader];
GO

/* (4) تأكيد: لازم ترجّع صفوف من الجداول اللي المزامنة بتقراها */
SELECT 'Vendor' t, COUNT(*) n FROM Vendor
UNION ALL SELECT 'pur_trans_h', COUNT(*) FROM pur_trans_h
UNION ALL SELECT 'pur_trans_d', COUNT(*) FROM pur_trans_d
UNION ALL SELECT 'Item_back_h', COUNT(*) FROM Item_back_h
UNION ALL SELECT 'Item_back_d', COUNT(*) FROM Item_back_d
UNION ALL SELECT 'Store',       COUNT(*) FROM Store
UNION ALL SELECT 'Employee',    COUNT(*) FROM Employee;
GO

/* (5) أهم رقم: أعلى فاتورة شراء في الفرع.
      مركز المزامنة بيزامن «الأجدد من آخر فاتورة» (last_pth)، فلو
      القاعدة استُعيدت من نسخة أقدم ورجع الترقيم لورا، الفواتير
      الجديدة هتفضل أقل من المؤشّر المخزّن وماتوصلش أبدًا —
      ساعتها نصفّر المؤشّر من مركز المزامنة («سحب فترة»). */
SELECT (SELECT MAX(pth_id) FROM pur_trans_h) AS max_purchase_id,
       (SELECT MAX(ibh_id) FROM Item_back_h) AS max_return_id;
GO
