# test_eplus_login.ps1 — فحص اتصال المزامنة بـeplus لفرع واحد أو كل الفروع
#
# بيشتغل على الجهاز اللي عليه محرّك المزامنة (جهاز المعمورة)، وبيقرا نفس
# ملف الإعدادات اللي المحرّك بيقراه — فالنتيجة هي بالظبط اللي المحرّك بيشوفه.
#
#   powershell -ExecutionPolicy Bypass -File scripts\test_eplus_login.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\test_eplus_login.ps1 -Branch bishr
#
# بيفرّق بين تلات حالات بتتلخبط في بعضها:
#   «Login failed»    = وصلنا للسيرفر ورفض الحساب → الحساب ناقص/كلمة سر غلط
#   «network-related» = مافيش وصول للسيرفر أصلًا  → عنوان/بورت/فايروول
#   «Cannot open database» = الحساب تمام بس مش مربوط بقاعدة Genius
#
# ⚠️ قراءة فقط — الاستعلام الوحيد هنا SELECT. وكلمة السر مابتتطبعش.

param(
  [string]$Branch = "",
  [string]$ConfigPath = "C:\ProgramData\phalix\sync_engine.json"
)
$ErrorActionPreference = "Stop"

try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
catch { Write-Host "تعذّر قراءة ملف الإعدادات: $ConfigPath" -ForegroundColor Red; exit 1 }

$names = if($Branch){ @($Branch) } else { $cfg.branches.PSObject.Properties.Name }

foreach($name in $names){
  $b = $cfg.branches.$name
  if(-not $b){ Write-Host "[$name] مافيش إعداد اتصال للفرع ده" -ForegroundColor Red; continue }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try{
    $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15")
    $cn.Open()
    $c = $cn.CreateCommand()
    $c.CommandText = "SELECT MAX(pth_id) FROM pur_trans_h"
    $c.CommandTimeout = 30
    $maxId = $c.ExecuteScalar()
    $cn.Close()
    Write-Host ("[{0}] تمام — {1} | أعلى فاتورة: {2} | {3} مللي ثانية" -f $name, $b.server, $maxId, $sw.ElapsedMilliseconds) -ForegroundColor Green
  }catch{
    $m = $_.Exception.Message
    # ملاحظة: PowerShell مابيسمحش بسطر جديد قبل elseif — لازم تفضل ملزوقة بالقوس
    $hint = ''
    if($m -match 'Login failed'){ $hint = 'الحساب مش موجود على السيرفر أو كلمة السر مختلفة — شوف docs\eplus_reader_setup.sql' }
    elseif($m -match 'network-related|not accessible|server was not found'){ $hint = 'مافيش وصول للسيرفر: العنوان/البورت/الفايروول' }
    elseif($m -match 'Cannot open database|server principal'){ $hint = 'الحساب موجود بس مش مربوط بقاعدة Genius (مستخدم يتيم)' }
    elseif($m -match 'Invalid object name'){ $hint = 'القاعدة متصلة بس الجداول مش موجودة — قاعدة غلط؟' }
    Write-Host ("[{0}] خطأ — {1} | {2} مللي ثانية" -f $name, $b.server, $sw.ElapsedMilliseconds) -ForegroundColor Red
    Write-Host ("        {0}" -f $m) -ForegroundColor DarkYellow
    if($hint){ Write-Host ("        → {0}" -f $hint) -ForegroundColor Cyan }
  }
}
