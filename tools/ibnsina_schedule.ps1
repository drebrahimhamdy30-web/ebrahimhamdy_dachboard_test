# ═══════════════════════════════════════════════════════════════════
#  جدولة مزامنة ابن سينا على جهاز الصيدلية
# ═══════════════════════════════════════════════════════════════════
#  ⚠️ ليه على الجهاز مش على السيرفر؟ Cloudflare بتاعة ابن سينا بتحجب
#     مراكز البيانات — نفس النداء بيرجّع 403 من سوبابيز ومن السيرفر
#     الذاتي، وبيعدّي من أي خط مصري عادي.
#
#  بيعمل مهمتين:
#   • التوفر  — كل ساعة، ~650 صنف، فالكتالوج بيتغطّى في 24 ساعة
#   • الأسعار — مرة يوميًا 6 صباحًا، 16 نداء بس (~30 ثانية)
#
#  التشغيل مرة واحدة من PowerShell **كمسؤول**:
#     .\tools\ibnsina_schedule.ps1
#  للإلغاء:
#     .\tools\ibnsina_schedule.ps1 -Remove
# ═══════════════════════════════════════════════════════════════════
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
$tasks = @('PhalixIbnSinaAvail', 'PhalixIbnSinaPrices')

if ($Remove) {
  foreach ($t in $tasks) {
    try { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Write-Host "اتشالت: $t" }
    catch { Write-Host "مش موجودة: $t" }
  }
  return
}

if (-not $node) { Write-Error 'Node.js مش متثبّت أو مش في PATH'; return }
if (-not (Test-Path "$repo\tools\ibnsina.local.json")) { Write-Error 'ملف الإعدادات ibnsina.local.json ناقص'; return }
Write-Host "الريبو: $repo"
Write-Host "Node:   $node"

# لو الجهاز كان مقفول وقت الميعاد، المهمة بتتنفّذ أول ما يشتغل
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
  -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
  -MultipleInstances IgnoreNew

# ── التوفر: كل ساعة ─────────────────────────────────────────────
$a1 = New-ScheduledTaskAction -Execute $node -Argument "tools\ibnsina_avail.js" -WorkingDirectory $repo
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(20) `
        -RepetitionInterval (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName $tasks[0] -Action $a1 -Trigger $t1 -Settings $settings -Force `
  -Description 'ابن سينا: فحص توفر ~650 صنف كل ساعة (الكتالوج كله في 24 ساعة)' | Out-Null
Write-Host "✓ $($tasks[0]) — كل ساعة عند الدقيقة 20"

# ── الأسعار: يوميًا 6 صباحًا ────────────────────────────────────
$a2 = New-ScheduledTaskAction -Execute $node -Argument "tools\ibnsina_pull.js" -WorkingDirectory $repo
$t2 = New-ScheduledTaskTrigger -Daily -At 6:00am
Register-ScheduledTask -TaskName $tasks[1] -Action $a2 -Trigger $t2 -Settings $settings -Force `
  -Description 'ابن سينا: سحب الأسعار والخصومات (16 نداء)' | Out-Null
Write-Host "✓ $($tasks[1]) — يوميًا 6 صباحًا"

Write-Host ''
Write-Host 'خلاص. تشوفهم في Task Scheduler تحت الاسمين دول.'
Write-Host 'لتجربة واحدة فورًا:  Start-ScheduledTask -TaskName PhalixIbnSinaAvail'
