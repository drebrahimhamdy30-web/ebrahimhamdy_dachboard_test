<#  trace_webconfig_writer.ps1 - يمسك البرنامج اللي بيكتب في web.config

    الليه: يوم 2026-11-15 وقف EPlusIntegrationAPI لان web.config كان مقفول من
    برنامج تاني وقت ما ASP.NET حاول يقراه. بعد الاصلاح اتلاحظ ان الملف بيتعدل
    كل ~12 دقيقة بنفس الحجم بالظبط (18:10:09 ثم 18:22:58، 4123 بايت).
    ملف اعدادات المفروض ميتلمسش شهور - فاللي بيكتبه هو السبب الجذري.

    بيستخدم تدقيق ويندوز (SACL + حدث 4663) اللي بيسجل اسم العملية والحساب.
    دي الطريقة الوحيدة اللي بتدي اجابة قاطعة من غير ادوات خارجية.

    الاستخدام:
      .\scripts\trace_webconfig_writer.ps1 -Enable    يشغل التدقيق
      .\scripts\trace_webconfig_writer.ps1 -Report    يعرض اللي اتمسك
      .\scripts\trace_webconfig_writer.ps1 -Disable   يوقف التدقيق وينضف
#>
param(
  [switch]$Enable,
  [switch]$Report,
  [switch]$Disable,
  [int]$Hours = 6,
  [string]$Target = "D:\EPlus API\ePlusIntegrationAPI\web.config"
)

$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 64); Write-Host "  $t"; Write-Host ("=" * 64) }

if (-not (Test-Path $Target)) { Write-Host "مالقيتش الملف: $Target"; return }

if ($Enable) {
  Head "تشغيل تدقيق الكتابة على web.config"
  try {
    $r = & auditpol.exe /set /subcategory:"File System" /success:enable /failure:enable 2>&1
    $r | ForEach-Object { Write-Host "  $_" }
  } catch { Write-Host "  فشل auditpol: $($_.Exception.Message)"; return }
  try {
    $acl  = Get-Acl -Path $Target -Audit
    $rule = New-Object System.Security.AccessControl.FileSystemAuditRule(
              "Everyone", "Write, Delete, WriteAttributes, ChangePermissions", "None", "None", "Success")
    $acl.AddAuditRule($rule)
    Set-Acl -Path $Target -AclObject $acl
    Write-Host "  تم تفعيل التدقيق على الملف"
    Write-Host ""
    Write-Host "  سيب الجهاز شغال 20-30 دقيقة علشان الكاتب يظهر، وبعدين:"
    Write-Host "    .\scripts\trace_webconfig_writer.ps1 -Report"
  } catch { Write-Host "  فشل ضبط SACL: $($_.Exception.Message)" }
  return
}

if ($Disable) {
  Head "ايقاف التدقيق وتنظيف"
  try {
    $acl = Get-Acl -Path $Target -Audit
    $acl.GetAuditRules($true, $false, [System.Security.Principal.NTAccount]) | ForEach-Object { $null = $acl.RemoveAuditRule($_) }
    Set-Acl -Path $Target -AclObject $acl
    Write-Host "  اتشالت قواعد التدقيق من الملف"
  } catch { Write-Host "  فشل: $($_.Exception.Message)" }
  & auditpol.exe /set /subcategory:"File System" /success:disable /failure:disable 2>&1 | ForEach-Object { Write-Host "  $_" }
  return
}

if ($Report) {
  Head "احداث الكتابة المسجلة (اخر $Hours ساعة)"
  $since = (Get-Date).AddHours(-$Hours)
  $ev = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4663; StartTime=$since } -ErrorAction SilentlyContinue
  if (-not $ev) { Write-Host "  مفيش احداث. يا اما التدقيق لسه ماتفعلش، يا اما الكاتب ماكتبش لسه."; return }
  $hits = $ev | Where-Object { $_.Message -match [regex]::Escape("web.config") }
  if (-not $hits) { Write-Host "  فيه احداث تدقيق بس مفيش منها على web.config"; return }
  $rows = $hits | ForEach-Object {
    $m = $_.Message
    $proc = if ($m -match "Process Name:\s*(.+)") { $Matches[1].Trim() } else { "?" }
    $acct = if ($m -match "Account Name:\s*(.+)") { $Matches[1].Trim() } else { "?" }
    [pscustomobject]@{ Time = $_.TimeCreated; Process = $proc; Account = $acct }
  }
  $rows | Select-Object -First 25 | Format-Table -AutoSize
  Head "تجميع حسب البرنامج"
  $rows | Group-Object Process | Sort-Object Count -Descending |
    ForEach-Object { "  {0,5} مرة   {1}" -f $_.Count, $_.Name }
  return
}

Head "حالة الملف"
$i = Get-Item $Target
"  اخر تعديل : $($i.LastWriteTime)"
"  الحجم     : $($i.Length) بايت"
try { $fs=[IO.File]::Open($Target,'Open','Read','None'); "  القفل     : حر"; $fs.Close() }
catch { "  القفل     : مقفول الان" }
Head "قواعد التدقيق الحالية"
try {
  $a = (Get-Acl -Path $Target -Audit).GetAuditRules($true,$false,[System.Security.Principal.NTAccount])
  if ($a.Count -eq 0) { "  مفيش - شغل -Enable" } else { $a | ForEach-Object { "  {0}  {1}  {2}" -f $_.IdentityReference, $_.FileSystemRights, $_.AuditFlags } }
} catch { "  تعذر: $($_.Exception.Message)" }
Write-Host ""
Write-Host "الاوامر: -Enable لبدء التتبع، -Report للنتيجة، -Disable للايقاف"