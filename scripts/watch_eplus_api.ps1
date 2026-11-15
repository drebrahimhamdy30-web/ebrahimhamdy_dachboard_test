<#  watch_eplus_api.ps1 - حارس eplus API: يرصد توقف التطبيق ويصلحه تلقائيا

    الليه: يوم 2026-11-15 وقف تطبيق EPlusIntegrationAPI بعد اعادة تشغيل الجهاز.
    ملف web.config اتقفل من برنامج تاني فـASP.NET فشل في الاقلاع، وبعد ما القفل
    اتفك فضل HTTP.sys في حالة بايظة: بيستقبل الاتصالات وما بيسلمهاش للعامل.
    اعادة تشغيل الـApp Pool مانفعتش - اللي نفع كان iisreset.
    فضلت شاشة التوزيع واقفة ساعات لحد ما حد لاحظ.

    الفحص: اي رد HTTP من البورت 8080 = حي (حتى 404 او 405).
            مفيش رد خالص = ميت.
    بيتأكد مرتين بفاصل 10 ثواني قبل ما يتصرف - عشان ميعملش iisreset من نبضة واحدة.
    وفيه سقف: مرة كل 15 دقيقة بحد اقصى.

    الاستخدام:
      .\scripts\watch_eplus_api.ps1            فحص وتقرير بس
      .\scripts\watch_eplus_api.ps1 -Apply     يعمل iisreset لو ميت
      .\scripts\watch_eplus_api.ps1 -Install   يسجل مهمة مجدولة كل 5 دقايق
#>
param(
  [switch]$Apply,
  [switch]$Install,
  [int]$TimeoutSec = 15,
  [int]$MinMinutesBetweenResets = 15
)

$ErrorActionPreference = "Continue"
$Url       = "http://localhost:8080/"
$LogDir    = "C:\phalix\logs"
$LogFile   = Join-Path $LogDir "eplus_api_watch.log"
$StampFile = Join-Path $LogDir "eplus_api_last_reset.txt"
$TaskName  = "Phalix - eplus API watchdog"

function Write-Log([string]$m) {
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}

function Test-ApiAlive {
  try {
    $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    return $true
  } catch {
    # رد HTTP بأي كود معناه التطبيق حي - اللي يهمنا هو الصمت التام
    if ($_.Exception.Response) { return $true }
    return $false
  }
}

if ($Install) {
  $self = $MyInvocation.MyCommand.Path
  Write-Host "سيتم تسجيل مهمة مجدولة:"
  Write-Host "  الاسم   : $TaskName"
  Write-Host "  الملف   : $self"
  Write-Host "  التكرار : كل 5 دقائق بحساب SYSTEM"
  if (-not $Apply) { Write-Host ""; Write-Host "عرض فقط. للتنفيذ ضيف -Apply مع -Install"; return }
  try {
    $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$self`" -Apply"
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t -Settings $s -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    Write-Log "تم تسجيل المهمة المجدولة: $TaskName"
  } catch { Write-Log "فشل تسجيل المهمة: $($_.Exception.Message)" }
  return
}

# ---------- الفحص ----------
if (Test-ApiAlive) { Write-Log "سليم - الـAPI بيرد"; return }

Write-Log "لا يوجد رد - اعادة الفحص بعد 10 ثواني للتأكد"
Start-Sleep -Seconds 10
if (Test-ApiAlive) { Write-Log "رجع يرد في الفحص التاني - مفيش تدخل"; return }

Write-Log "مؤكد: الـAPI مش بيرد في فحصين متتاليين"

if (-not $Apply) { Write-Log "عرض فقط - للتصليح شغل السكربت بـ-Apply"; return }

# سقف زمني: ما نعملش iisreset ورا بعضه
if (Test-Path $StampFile) {
  $last = Get-Content $StampFile -Raw -ErrorAction SilentlyContinue
  $dt = [datetime]::MinValue
  if ([datetime]::TryParse($last, [ref]$dt)) {
    $mins = ((Get-Date) - $dt).TotalMinutes
    if ($mins -lt $MinMinutesBetweenResets) {
      Write-Log ("تم عمل iisreset من {0:N0} دقيقة - الانتظار حتى {1} دقيقة قبل المحاولة تاني" -f $mins, $MinMinutesBetweenResets)
      Write-Log "لو العطل مستمر بعد عدة محاولات فالسبب مش HTTP.sys - راجع سجل الاحداث"
      return
    }
  }
}

Write-Log "تنفيذ iisreset /restart"
try {
  $out = & iisreset.exe /restart 2>&1
  $out | ForEach-Object { Write-Log "  $_" }
  Set-Content -Path $StampFile -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8
} catch { Write-Log "فشل iisreset: $($_.Exception.Message)"; return }

Start-Sleep -Seconds 15
if (Test-ApiAlive) { Write-Log "تم الاصلاح - الـAPI رجع يرد" }
else { Write-Log "لسه مش بيرد بعد iisreset - يحتاج تدخل يدوي (راجع Event Log / ASP.NET 3008)" }