# grant_contract_writer_system.ps1
# نفس هدف grant_contract_writer.ps1، بس بينفّذ كـNT AUTHORITY\SYSTEM.
#
# ليه؟ حساب الويندوز اللي على السيرفر (MASTER\USER) **مش sysadmin**
# على SQL، وباسورد sa مجهول. و`NT AUTHORITY\SYSTEM` سيسأدمن افتراضيًا
# على SQL Server 2000 — بنوصله عبر **مهمة مجدولة مؤقتة** تتعمل وتتشغّل
# وتتمسح. (نفس الطريقة اللي استرجعنا بيها phalix_reader في سيدي بشر.)
#
# ⚠️ صيغة SQL 2000: sp_addlogin / sp_grantdbaccess / sp_change_users_login
#    مش CREATE LOGIN بتاعة 2005.
#
# يتطلب: المستخدم الحالي **أدمن ويندوز** (عشان يقدر يعمل مهمة SYSTEM).
# مابيعدّلش أي بيانات — صلاحيات بس.
#
# التشغيل:  .\grant_contract_writer_system.ps1

param([System.Security.SecureString]$WriterPassword)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m){ Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# لازم أدمن ويندوز عشان نعمل مهمة بـ/ru SYSTEM
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L "وقّف: افتح PowerShell كـ(Run as Administrator) الأول."; exit 1 }

if (-not $WriterPassword) { $WriterPassword = Read-Host "باسورد phalix_writer الجديد" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($WriterPassword))
if ([string]::IsNullOrWhiteSpace($pw)) { L "وقّف: الباسورد فاضي."; exit 1 }
# الباسورد داخل نص SQL — الكوت المفرد لازم يتضاعف
$pwSql = $pw -replace "'", "''"

# مجلد مؤقت خارج الريبو (الريبو عام — ممنوع أي ملف فيه باسورد)
$tmp = Join-Path $env:TEMP ("phx_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$sqlFile = Join-Path $tmp "grant.sql"
$batFile = Join-Path $tmp "run.bat"
$outFile = Join-Path $tmp "out.txt"

$sql = @"
EXEC sp_addlogin 'phalix_writer', '$pwSql', 'Genius'
GO
USE Genius
GO
EXEC sp_grantdbaccess 'phalix_writer'
GO
-- لو التسجيل كان موجود من قبل بـSID قديم، ده بيربطه بالمستخدم
EXEC sp_change_users_login 'Update_One', 'phalix_writer', 'phalix_writer'
GO
GRANT SELECT, UPDATE ON Customer_Contracts TO phalix_writer
GO
GRANT SELECT ON Customer TO phalix_writer
GO
GRANT SELECT ON sales_trans_h TO phalix_writer
GO
GRANT SELECT ON sales_trans_d TO phalix_writer
GO
SELECT 'contracts_active=' + CAST(COUNT(*) AS varchar(10)) FROM Customer_Contracts WHERE cc_active = 1
GO
"@
# ANSI عشان osql بتاع 2000 — والملف مفيهوش عربي أصلًا
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

# تحقق مستقل: الحساب بيتصل ويعدّل؟
try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=phalix_writer;Password=$pw;Connect Timeout=20")
  $cn.Open()
  $c = $cn.CreateCommand()
  $c.CommandText = "SELECT COUNT(*) FROM Customer_Contracts WHERE cc_active=1"
  L ("phalix_writer بيتصل ويقرا ✓ — عقود شغّالة: " + $c.ExecuteScalar())
  # تعديل بلا أثر جوّه ترانزاكشن مرتجعة — بيثبت الصلاحية من غير ما يغيّر حاجة
  $c.CommandText = "BEGIN TRAN; UPDATE Customer_Contracts SET sec_update_date = sec_update_date WHERE 1=0; ROLLBACK;"
  [void]$c.ExecuteNonQuery()
  L "وصلاحية التعديل شغّالة ✓"
  $cn.Close()
  L ""
  L "تمام. الخطوة الجاية (عرض بس، مفيش تعديل):"
  L "   .\update_contract_percent.ps1 -Password '<الباسورد>'"
} catch {
  L "❌ التحقق فشل: $($_.Exception.Message)"
  L "   لو الرسالة 'Login failed' يبقى المهمة ماشتغلتش كـSYSTEM — ابعتلي ناتج osql فوق."
}
