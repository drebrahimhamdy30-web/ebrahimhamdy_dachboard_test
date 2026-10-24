# grant_contract_writer.ps1
# ينشئ/يحدّث حساب phalix_writer ويديله صلاحية **قراءة وتعديل على
# Customer_Contracts فقط** — عشان نقدر نعدّل نسبة خصم عقد التعاقد.
#
# ليه سكربت منفصل عن create_writer.ps1؟
#   ده بيدي صلاحية على جدول واحد بس. خلطه مع صلاحيات الفواتير
#   المعلّقة كان هيدّي الحساب صلاحيات مش محتاجينها دلوقتي.
#
# ⚠️ لازم يتشغّل **على سيرفر الفرع نفسه** بحساب ويندوز sysadmin
#    (Administrator، أو NT AUTHORITY\SYSTEM عبر Scheduled Task).
#    التريستد كونيكشن لازم يبقى محلي — مش من جهاز تاني.
#
# السكربت ده **مابيعدّلش أي بيانات**. التعديل في سكربت تاني.

# ====== املا الباسورد ده بس ======
$WriterPwd = "ضع_باسورد_قوي_هنا"
$Server    = "localhost,1433"
# =================================

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$log = Join-Path $PSScriptRoot "grant_contract_writer.log"
function L($m){ $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
                Add-Content -Path $log -Value $line -Encoding UTF8; Write-Host $line }
Remove-Item $log -ErrorAction SilentlyContinue

if ($WriterPwd -eq "ضع_باسورد_قوي_هنا") { L "وقّف: املا الباسورد الأول في أول السكربت."; exit 1 }

try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=master;Integrated Security=SSPI;Connect Timeout=20")
  $cn.Open()
  L "اتصلنا بحساب ويندوز: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
} catch { L "فشل الاتصال (غالبًا مش sysadmin أو مش على السيرفر نفسه): $($_.Exception.Message)"; exit 1 }

function Exec($sql){ $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60; [void]$c.ExecuteNonQuery() }
function Try1($sql,$label){ try{ Exec $sql; L "OK  - $label" } catch { L "..  - $label : $($_.Exception.Message)" } }

# الحساب ممكن يكون اتعمل قبل كده — الفشل هنا مش مشكلة
Try1 "EXEC sp_addlogin 'phalix_writer', '$WriterPwd', 'Genius'" "إنشاء اللوجن phalix_writer"
Try1 "USE Genius; EXEC sp_grantdbaccess 'phalix_writer'"        "دخول قاعدة Genius"
Try1 "USE Genius; GRANT SELECT, UPDATE ON Customer_Contracts TO phalix_writer" "صلاحية قراءة وتعديل على Customer_Contracts"
# القراءة دي محتاجينها للتحقق بعد التعديل (نشوف الخصم اتطبّق على البنود)
Try1 "USE Genius; GRANT SELECT ON Customer TO phalix_writer"          "قراءة Customer"
Try1 "USE Genius; GRANT SELECT ON sales_trans_h TO phalix_writer"     "قراءة sales_trans_h"
Try1 "USE Genius; GRANT SELECT ON sales_trans_d TO phalix_writer"     "قراءة sales_trans_d"
$cn.Close()

# تحقق: الحساب بيتصل ويشوف العقود
try {
  $t = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Genius;User ID=phalix_writer;Password=$WriterPwd;Connect Timeout=20")
  $t.Open()
  $c = $t.CreateCommand()
  $c.CommandText = "SELECT COUNT(*) FROM Customer_Contracts WHERE cc_active=1"
  $n = $c.ExecuteScalar()
  L "تم بنجاح. phalix_writer بيتصل ويقرا — عقود شغّالة: $n"
  # تحقق إضافي: هل عنده صلاحية تعديل فعلًا؟ (بنجرّب تعديل بلا أثر جوّه ترانزاكشن مرتجعة)
  $c.CommandText = "BEGIN TRAN; UPDATE Customer_Contracts SET sec_update_date = sec_update_date WHERE 1=0; ROLLBACK;"
  [void]$c.ExecuteNonQuery()
  L "وصلاحية التعديل شغّالة ✓"
  $t.Close()
} catch { L "الحساب اتعمل بس التحقق فشل: $($_.Exception.Message)" }

L "خلص. الخطوة الجاية: شغّل update_contract_percent.ps1 (بيعرض الأرقام الأول قبل ما يعدّل)."
