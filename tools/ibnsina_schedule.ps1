# ═══════════════════════════════════════════════════════════════════
#  جدولة مزامنة ابن سينا على جهاز الصيدلية
# ═══════════════════════════════════════════════════════════════════
#  ⚠️ ليه على الجهاز مش على السيرفر؟ Cloudflare بتاعة ابن سينا بتحجب
#     مراكز البيانات — نفس النداء بيرجّع 403 من سوبابيز ومن السيرفر
#     الذاتي، وبيعدّي من أي خط مصري عادي.
#
#  بيعمل مهمتين:
#   • التوفر  — كل ساعة، ~650 صنف، فالكتالوج بيتغطّى في 24 ساعة
#   • الضريبة — يوميًا 5:45ص، بيلقط الفواتير الجديدة (ثانيتين لو مفيش)
#   • الأسعار — مرة يوميًا 6 صباحًا، 16 نداء بس (~30 ثانية)
#
#  ⚠️ ترتيب الضريبة قبل الأسعار **مقصود**: الفاتورة الجديدة بتحوّل
#     أصناف من «ضريبة مستنتجة» لـ«مقطوع فيها»، وسحب الأسعار بعدها
#     بيحسب خصومها صح من أول يوم. لو اتعكس الترتيب الفايدة بتتأخر يوم.
#
#  التشغيل مرة واحدة من PowerShell:
#     .\tools\ibnsina_schedule.ps1
#
#  على جهاز شغّال 24 ساعة استعمل -AsSystem: المهمة تشتغل حتى لو
#  محدش عامل تسجيل دخول. من غيرها بتشتغل بس والمستخدم داخل.
#     .\tools\ibnsina_schedule.ps1 -AsSystem      (محتاج صلاحية مسؤول)
#  للإلغاء:
#     .\tools\ibnsina_schedule.ps1 -Remove
# ═══════════════════════════════════════════════════════════════════
param([switch]$Remove, [switch]$AsSystem)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
$tasks = @('PhalixIbnSinaAvail', 'PhalixIbnSinaTax', 'PhalixIbnSinaPrices')

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

# على جهاز 24 ساعة: SYSTEM بيشتغل من غير ما حد يكون داخل بحسابه.
# من غيره المهمة بتستنى تسجيل دخول المستخدم.
$principal = $null
if ($AsSystem) {
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Write-Host 'الوضع: SYSTEM — هتشتغل حتى لو محدش داخل'
} else {
  Write-Host 'الوضع: المستخدم الحالي — هتشتغل بس والمستخدم داخل (استعمل -AsSystem لجهاز 24 ساعة)'
}
function Register-Phalix($name, $action, $trigger, $desc) {
  $p = @{ TaskName = $name; Action = $action; Trigger = $trigger; Settings = $settings; Description = $desc; Force = $true }
  if ($principal) { $p.Principal = $principal }
  Register-ScheduledTask @p | Out-Null
}

# ── التوفر: كل ساعة ─────────────────────────────────────────────
$a1 = New-ScheduledTaskAction -Execute $node -Argument "tools\ibnsina_avail.js" -WorkingDirectory $repo
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(20) `
        -RepetitionInterval (New-TimeSpan -Hours 1)
Register-Phalix $tasks[0] $a1 $t1 'ابن سينا: فحص توفر ~650 صنف كل ساعة (الكتالوج كله في 24 ساعة)'
Write-Host "✓ $($tasks[0]) — كل ساعة عند الدقيقة 20"

# ── الضريبة: يوميًا 5:45 صباحًا (قبل الأسعار) ───────────────────
# بيقرا الفواتير الجديدة بس. كل فاتورة بتحوّل أصنافها من ضريبة
# مستنتجة (دقة 96.5%) لضريبة مقطوع فيها. لو مفيش فاتورة جديدة
# بيقف بعد 3 نداءات. من غير --classify — التصنيف اتقاس وطلع
# بيحسم 9% بس من الأصناف.
$a3 = New-ScheduledTaskAction -Execute $node -Argument "tools\ibnsina_tax_map.js --daily" -WorkingDirectory $repo
$t3 = New-ScheduledTaskTrigger -Daily -At 5:45am
Register-Phalix $tasks[1] $a3 $t3 'ابن سينا: لقط الفواتير الجديدة وتحديث خريطة الضريبة'
Write-Host "✓ $($tasks[1]) — يوميًا 5:45 صباحًا"

# ── الأسعار: يوميًا 6 صباحًا ────────────────────────────────────
$a2 = New-ScheduledTaskAction -Execute $node -Argument "tools\ibnsina_pull.js" -WorkingDirectory $repo
$t2 = New-ScheduledTaskTrigger -Daily -At 6:00am
Register-Phalix $tasks[2] $a2 $t2 'ابن سينا: سحب الأسعار والخصومات (16 نداء)'
Write-Host "✓ $($tasks[2]) — يوميًا 6 صباحًا"

Write-Host ''
Write-Host 'خلاص. تشوفهم في Task Scheduler تحت التلات أسامي دول.'
Write-Host 'لتجربة واحدة فورًا:  Start-ScheduledTask -TaskName PhalixIbnSinaAvail'
