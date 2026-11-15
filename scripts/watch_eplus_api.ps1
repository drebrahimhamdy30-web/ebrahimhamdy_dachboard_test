<#  watch_eplus_api.ps1 - حارس eplus API

    الليه: يوم 2026-11-15 وقف تطبيق EPlusIntegrationAPI وفضلت شاشة التوزيع
    واقفة ساعات لحد ما حد لاحظ. والسبب النهائي طلع مفاجئ: بورت 8080 مكانش
    له قاعدة في جدار الحماية، فالتطبيق كان بيرد محليا تمام لكن مش طالع
    للشبكة - فnginx على سيرفر n8n ميقدرش يوصله وCloudflare يرجع 502/504.

    دروس النسخة الاولى اللي اتصلحت هنا:
      1) iisreset.exe بيفشل بـAccess denied لما يتشغل بحساب SYSTEM من مهمة
         مجدولة. بقى Restart-Service W3SVC.
      2) كان بيسجل نجاح الاصلاح من غير ما يتأكد، فيمنع نفسه 15 دقيقة على
         اساس انه نجح. بقى يتحقق من حالة الخدمة بعد اعادة التشغيل.
      3) مهلة 15 ثانية كانت اقصر من زمن الاستعلام الطبيعي (30 ثانية)، فكان
         ممكن يحكم بالموت على تطبيق سليم. بقت 60 ثانية.
      4) كان بيفحص المحلي بس - وعطل النهاردة كان في الشبكة مش في التطبيق.
         ضفنا فحص وجود قاعدة الجدار.

    ملحوظة: الاتصال من الجهاز لعنوانه الخاص بيعدي على loopback وبيتخطى
    الجدار، فمينفعش نكتشف الحجب بنداء محلي. عشان كده بنفحص وجود القاعدة.

    الاستخدام:
      .\scripts\watch_eplus_api.ps1              فحص وتقرير بس
      .\scripts\watch_eplus_api.ps1 -Apply       يصلح لو فيه عطل
      .\scripts\watch_eplus_api.ps1 -Install -Apply   يسجل مهمة كل 5 دقايق
      .\scripts\watch_eplus_api.ps1 -Uninstall   يشيل المهمة
#>
param(
  [switch]$Apply,
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$FixFirewall,
  [int]$TimeoutSec = 60,
  [int]$MinMinutesBetweenResets = 15
)

$ErrorActionPreference = "Continue"
$Url       = "http://localhost:8080/"
$LogDir    = "C:\phalix\logs"
$LogFile   = Join-Path $LogDir "eplus_api_watch.log"
$StampFile = Join-Path $LogDir "eplus_api_last_reset.txt"
$TaskName  = "Phalix - eplus API watchdog"
$FwName    = "EPlus API 8080-8081 (ZeroTier)"
$ZtSubnet  = "192.168.192.0/24"

function Write-Log([string]$m) {
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}

function Test-ApiAlive {
  try { $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop; return $true }
  catch { if ($_.Exception.Response) { return $true }; return $false }   # اي رد HTTP = حي
}

function Test-FirewallRule {
  try {
    $r = Get-NetFirewallRule -DisplayName $FwName -ErrorAction Stop
    if (-not $r.Enabled) { return "disabled" }
    return "ok"
  } catch { return "missing" }
}

if ($Uninstall) {
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Log "اتشالت المهمة المجدولة" }
  catch { Write-Log "مفيش مهمة بالاسم ده" }
  return
}

if ($Install) {
  $self = $MyInvocation.MyCommand.Path
  Write-Host "المهمة المجدولة:"
  Write-Host "  الاسم   : $TaskName"
  Write-Host "  الملف   : $self"
  Write-Host "  التكرار : كل 5 دقائق بحساب SYSTEM"
  if (-not $Apply) { Write-Host ""; Write-Host "عرض فقط. للتنفيذ: -Install -Apply"; return }
  try {
    $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$self`" -Apply"
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t -Settings $s -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    Write-Log "اتسجلت المهمة المجدولة: $TaskName"
  } catch { Write-Log "فشل التسجيل: $($_.Exception.Message)" }
  return
}

# ---------- 1) قاعدة الجدار ----------
$fw = Test-FirewallRule
if ($fw -ne "ok") {
  Write-Log "تحذير: قاعدة الجدار '$FwName' $(if($fw -eq 'missing'){'مش موجودة'}else{'موجودة بس متعطلة'})"
  Write-Log "  يعني التطبيق ممكن يرد محليا وميوصلش للشبكة - ده بالظبط عطل 2026-11-15"
  if ($Apply -and $FixFirewall) {
    try {
      if ($fw -eq "missing") {
        New-NetFirewallRule -DisplayName $FwName -Direction Inbound -Protocol TCP -LocalPort 8080,8081 -RemoteAddress $ZtSubnet -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-Log "  اتعملت القاعدة من جديد (مقصورة على $ZtSubnet)"
      } else {
        Enable-NetFirewallRule -DisplayName $FwName -ErrorAction Stop
        Write-Log "  اتفعّلت القاعدة"
      }
    } catch { Write-Log "  فشل ضبط القاعدة: $($_.Exception.Message)" }
  } else {
    Write-Log "  للاصلاح التلقائي ضيف -FixFirewall مع -Apply"
  }
} else {
  Write-Log "قاعدة الجدار موجودة ومفعّلة"
}

# ---------- 2) حياة التطبيق ----------
if (Test-ApiAlive) { Write-Log "سليم - الـAPI بيرد"; return }

Write-Log "لا يوجد رد - اعادة الفحص بعد 10 ثواني للتأكد"
Start-Sleep -Seconds 10
if (Test-ApiAlive) { Write-Log "رد في الفحص التاني - مفيش تدخل"; return }

Write-Log "مؤكد: الـAPI مش بيرد في فحصين متتاليين (مهلة $TimeoutSec ثانية)"
if (-not $Apply) { Write-Log "عرض فقط - للتصليح شغله بـ-Apply"; return }

if (Test-Path $StampFile) {
  $dt = [datetime]::MinValue
  if ([datetime]::TryParse((Get-Content $StampFile -Raw -ErrorAction SilentlyContinue), [ref]$dt)) {
    $mins = ((Get-Date) - $dt).TotalMinutes
    if ($mins -lt $MinMinutesBetweenResets) {
      Write-Log ("اتعملت اعادة تشغيل ناجحة من {0:N0} دقيقة - استنى لحد {1} دقيقة" -f $mins, $MinMinutesBetweenResets)
      Write-Log "لو العطل مستمر فالسبب مش IIS - راجع Event Log وقاعدة الجدار"
      return
    }
  }
}

Write-Log "اعادة تشغيل W3SVC (مش iisreset - بيفشل بحساب SYSTEM)"
try {
  Restart-Service -Name W3SVC -Force -ErrorAction Stop
  Start-Sleep -Seconds 8
} catch { Write-Log "فشل اعادة التشغيل: $($_.Exception.Message)"; return }

$svc = Get-Service W3SVC -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne "Running") { Write-Log "W3SVC مش Running بعد المحاولة - تدخل يدوي مطلوب"; return }
Write-Log "W3SVC رجع Running"

Start-Sleep -Seconds 7
if (Test-ApiAlive) {
  Write-Log "تم الاصلاح - الـAPI رجع يرد"
  Set-Content -Path $StampFile -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8   # الختم عند النجاح بس
} else {
  Write-Log "لسه مش بيرد بعد اعادة التشغيل - السبب مش IIS"
  Write-Log "  افحص: Event Log (ASP.NET 3008)، قفل web.config، قاعدة الجدار"
}