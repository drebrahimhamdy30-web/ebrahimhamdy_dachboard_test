# grant_wallet_writer_system.ps1
# بيدّي phalix_writer الصلاحيات المطلوبة لصرف المحافظ:
#   GRANT SELECT, INSERT, UPDATE ON F_Transaction_Header  (صف الصرف + fh_code)
#   GRANT SELECT, UPDATE         ON F_Cash_Store          (الرصيدين)
#   GRANT SELECT                 ON Employee              (اسم اللي طبع الفاتورة -> e_id)
#
# ⚠️ نسخة طبق الأصل من grant_region_writer_system.ps1 — ده السكربت الوحيد
#    اللي ثبت إنه نجح فعلًا على سيرفر سان (144 كتابة منطقة ناجحة). نسخة
#    سابقة بـC:WindowsTemp رجّعت 0xC0000142 وماشتغلتش، فالاختلاف الوحيد
#    المسموح بيه هنا هو جُمل الـGRANT.
#
# بينفّذ كـNT AUTHORITY\SYSTEM عبر مهمة مجدولة مؤقتة (نفس أسلوب
# grant_contract_writer_system.ps1) لأن مستخدم الويندوز مش sysadmin.
# صيغة SQL 2000. التسجيل phalix_writer موجود بالفعل — فمفيش إنشاء، جرانت بس.
# مابيعدّلش أي بيانات — صلاحيات فقط.
#
# يتطلب: PowerShell كـ(Run as Administrator).
# التشغيل:  .\grant_region_writer_system.ps1

param([System.Security.SecureString]$WriterPassword)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m){ Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L "وقّف: افتح PowerShell كـ(Run as Administrator) الأول."; exit 1 }

$tmp = Join-Path $env:TEMP ("phx_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$sqlFile = Join-Path $tmp "grant.sql"
$batFile = Join-Path $tmp "run.bat"
$outFile = Join-Path $tmp "out.txt"

$sql = @"
USE Genius
GO
GRANT SELECT, INSERT, UPDATE ON F_Transaction_Header TO phalix_writer
GO
GRANT SELECT, UPDATE ON F_Cash_Store TO phalix_writer
GO
GRANT SELECT ON Employee TO phalix_writer
GO
SELECT 'wallets=' + CAST(COUNT(*) AS varchar(12)) FROM F_Cash_Store WHERE fcs_type = 3
GO
SELECT 'server=' + @@SERVERNAME
GO
"@
[IO.File]::WriteAllText($sqlFile, $sql, [Text.Encoding]::Default)
[IO.File]::WriteAllText($batFile, "osql -E -S . -i `"$sqlFile`" -o `"$outFile`"`r`n", [Text.Encoding]::ASCII)

$task = "phx_grant_" + (Get-Random -Maximum 99999)
try {
  L "بعمل مهمة مؤقتة تشتغل كـSYSTEM..."
  & schtasks /create /tn $task /tr "`"$batFile`"" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f | Out-Null
  & schtasks /run /tn $task | Out-Null
  L "بتشغّل وبستنى..."
  $waited = 0
  while (-not (Test-Path $outFile) -and $waited -lt 60) { Start-Sleep -Seconds 2; $waited += 2 }
  Start-Sleep -Seconds 3
  if (Test-Path $outFile) {
    L "ناتج osql:"
    Get-Content $outFile | Where-Object { $_.Trim() } | ForEach-Object { "    $_" }
  } else { L "⚠️ مطلعش ناتج — المهمة غالبًا ماشتغلتش." }
} finally {
  & schtasks /delete /tn $task /f 2>$null | Out-Null
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  L "المهمة والملفات المؤقتة اتمسحوا."
}

# تحقق مستقل (اختياري): الحساب بيقرا المناطق ويعدّل عنوان بلا أثر؟
if (-not $WriterPassword) { $WriterPassword = Read-Host "باسورد phalix_writer للتحقق (Enter لتخطّيه)" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($WriterPassword))
if ([string]::IsNullOrWhiteSpace($pw)) { L "اتخطّى التحقق (مفيش باسورد). الجرانت فوق هو المهم."; exit 0 }
try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=phalix_writer;Password=$pw;Connect Timeout=20")
  $cn.Open()
  $c = $cn.CreateCommand()
  $c.CommandText = "SELECT COUNT(*) FROM Delivery_cost_region"
  L ("phalix_writer بيقرا المناطق ✓ — عددها: " + $c.ExecuteScalar())
  # تعديل بلا أثر جوّه ترانزاكشن مرتجعة — يثبت صلاحية UPDATE على Customer_Delivery
  $c.CommandText = "BEGIN TRAN; UPDATE Customer_Delivery SET sec_update_date = sec_update_date WHERE 1=0; ROLLBACK;"
  [void]$c.ExecuteNonQuery()
  L "وصلاحية UPDATE على Customer_Delivery شغّالة ✓"
  $cn.Close()
  L ""; L "تمام. الخطوة الجاية: شغّل سكربت الكتابة (عرض بس):  .\region_writeback.ps1"
} catch {
  L "❌ التحقق فشل: $($_.Exception.Message)"
  L "   لو 'Login failed' يبقى الباسورد غلط أو المهمة ماشتغلتش كـSYSTEM — ابعتلي ناتج osql فوق."
}
