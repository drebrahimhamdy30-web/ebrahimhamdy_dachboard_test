<#  diag_eplus_origin.ps1 — تشخيص بطء/انهيار سيرفر eplus للمعمورة
    يتشغّل على MASTER (192.168.192.100) — ده جهاز المعمورة نفسه.
    قراءة فقط افتراضيًا. لإعادة تشغيل الـApp Pool ضيف -Recycle
    الاستخدام:  cd C:\phalix\dashboard ; git pull ; .\scripts\diag_eplus_origin.ps1
#>
param([switch]$Recycle)

$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 60); Write-Host "  $t"; Write-Host ("=" * 60) }

Head "1) حمل الجهاز"
try {
  $c = Get-Counter "Processor(_Total)% Processor Time","MemoryAvailable MBytes" -SampleInterval 2 -MaxSamples 2 -ErrorAction Stop
  $cpu = [math]::Round((($c.CounterSamples | Where-Object { $_.Path -like "*Processor*" }).CookedValue | Measure-Object -Average).Average,1)
  $mem = [math]::Round((($c.CounterSamples | Where-Object { $_.Path -like "*Memory*"    }).CookedValue | Measure-Object -Average).Average,0)
  Write-Host "  المعالج: $cpu %   ·   الذاكرة المتاحة: $mem ميجا"
  if ($cpu -gt 85) { Write-Host "  ⚠️ المعالج مخنوق" }
  if ($mem -lt 500) { Write-Host "  ⚠️ الذاكرة المتاحة قليلة" }
} catch { Write-Host "  تعذّر قياس الحمل: $($_.Exception.Message)" }

Head "2) حالة IIS — تطبيق ePlus API"
$pools = @()
try {
  Import-Module WebAdministration -ErrorAction Stop
  $pools = Get-ChildItem IIS:AppPools -ErrorAction Stop
  foreach ($p in $pools) {
    $mark = if ($p.State -eq "Started") { "✅" } else { "❌" }
    Write-Host ("  {0} {1,-28} {2}" -f $mark, $p.Name, $p.State)
  }
  $w3 = Get-Process w3wp -ErrorAction SilentlyContinue
  if ($w3) {
    Write-Host ""
    Write-Host "  عمليات w3wp (عامل IIS):"
    foreach ($p in $w3) {
      $mb = [math]::Round($p.WorkingSet64/1MB,0)
      $up = [math]::Round(((Get-Date) - $p.StartTime).TotalMinutes,0)
      Write-Host ("    PID {0,-7} ذاكرة {1,6} ميجا   شغال من {2} دقيقة" -f $p.Id, $mb, $up)
      if ($up -lt 5) { Write-Host "      ⚠️ اتولدت من شوية — يعني الـPool بيتهار ويرجع" }
    }
  } else { Write-Host "  ⚠️ مفيش أي عملية w3wp — IIS مش بيخدم أي طلبات" }
} catch { Write-Host "  تعذّر قراءة IIS: $($_.Exception.Message)" }

Head "3) استعلامات SQL المعلّقة والمتعارضة (قاعدة Genius)"
$q = "SET NOCOUNT ON; SELECT spid, status, blocked, waittype, DATEDIFF(second,last_batch,GETDATE()) AS secs, RTRIM(program_name) AS prog FROM master..sysprocesses WHERE dbid = DB_ID('Genius') AND spid > 50 ORDER BY secs DESC"
$osql = @("osql") + @(Get-ChildItem "C:Program Files*Microsoft SQL Server*ToolsBinnosql.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$ran = $false
foreach ($exe in $osql) {
  try {
    $out = & $exe -E -Q $q -w 400 -h-1 2>&1
    if ($LASTEXITCODE -eq 0) { $out | ForEach-Object { Write-Host "  $_" }; $ran = $true; break }
  } catch { }
}
if (-not $ran) { Write-Host "  تعذّر تشغيل osql — جرّب: sqlcmd -E -Q \"...\"  أو افتح Query Analyzer" }
Write-Host ""
Write-Host "  اقرأها كده: blocked ≠ 0 يعني الجلسة مستنية جلسة تانية (تعارض)."
Write-Host "             secs بالمئات يعني استعلام شغال من زمان."

Head "4) هل الـAPI بيرد محليًا؟"
foreach ($u in @("http://localhost/","http://localhost/ePlusIntegrationAPI/")) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    $sw.Stop(); Write-Host ("  ✅ {0,-38} HTTP {1} في {2:N2} ثانية" -f $u, $r.StatusCode, $sw.Elapsed.TotalSeconds)
  } catch {
    $sw.Stop()
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code) { Write-Host ("  ⚠️ {0,-38} HTTP {1} في {2:N2} ثانية" -f $u, $code, $sw.Elapsed.TotalSeconds) }
    else       { Write-Host ("  ❌ {0,-38} مفيش رد في {1:N2} ثانية" -f $u, $sw.Elapsed.TotalSeconds) }
  }
}
Write-Host ""
Write-Host "  لو بيرد محليًا بسرعة والخارج بطيء → المشكلة في النفق/الشبكة."
Write-Host "  لو بطيء محليًا كمان → المشكلة في IIS أو SQL (البندين 2 و3)."

if ($Recycle) {
  Head "5) إعادة تشغيل App Pool"
  $t = $pools | Where-Object { $_.Name -match "plus|api" }
  if (-not $t) { Write-Host "  مالقيتش Pool اسمه فيه plus أو api — أعد التشغيل يدوي من IIS Manager" }
  foreach ($p in $t) {
    try { Restart-WebAppPool -Name $p.Name -ErrorAction Stop; Write-Host "  ✅ اتعمل recycle لـ: $($p.Name)" }
    catch { Write-Host "  ❌ فشل $($p.Name): $($_.Exception.Message)" }
  }
} else {
  Write-Host ""
  Write-Host "— للتشخيص بس. لإعادة تشغيل الـApp Pool: .scriptsdiag_eplus_origin.ps1 -Recycle"
}
