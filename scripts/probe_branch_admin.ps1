# probe_branch_admin.ps1
# بيجرّب لكل فرع: هل نقدر نعمل حساب الكتابة **عن بُعد** من الماستر؟
# **قراءة/فحص فقط** — مابيعملش حساب ولا بيعدّل حاجة.
#
# بيجرّب مسارين:
#   (أ) اتصال SQL بحساب ويندوز الحالي (Integrated Security) — لو نجح
#       وطلع sysadmin، نقدر نعمل الحساب بأمر SQL عادي من هنا.
#   (ب) مهمة مجدولة عن بُعد (schtasks /s) — بتحتاج يكون حسابك أدمن
#       ويندوز على السيرفر البعيد.
# لو الاتنين فشلوا، لازم تدخل على سيرفر الفرع بنفسه.

param([string]$ConfigPath = "C:\phalix\sync_engine.json")

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not (Test-Path $ConfigPath)) { Write-Host "مش لاقي $ConfigPath"; exit 1 }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

Write-Host ("حسابك الحالي: {0}`n" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)

foreach ($p in $cfg.branches.PSObject.Properties) {
  $name = $p.Name; $srv = $p.Value.server
  Write-Host ("=== {0}  ({1})" -f $name, $srv)

  # (أ) هل حساب الويندوز بتاعي sysadmin على SQL بتاعهم؟
  $canSql = $false
  try {
    $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$srv;Database=master;Integrated Security=SSPI;Connect Timeout=10")
    $cn.Open()
    $c = $cn.CreateCommand()
    $c.CommandText = "SELECT IS_SRVROLEMEMBER('sysadmin')"
    $isSa = $c.ExecuteScalar()
    $cn.Close()
    if ($isSa -eq 1) { Write-Host "   ✓ (أ) حساب ويندوزك sysadmin على SQL → نقدر نعمل الحساب من هنا"; $canSql = $true }
    else            { Write-Host "   ~ (أ) الاتصال نجح بس **مش** sysadmin" }
  } catch { Write-Host ("   ✗ (أ) اتصال ويندوز فشل: {0}" -f $_.Exception.Message.Split([Environment]::NewLine)[0]) }

  # (ب) هل أقدر أعمل مهمة مجدولة على السيرفر البعيد؟
  if (-not $canSql) {
    $host_ = ($srv -split ',')[0]
    if ($host_ -in @('localhost','.','127.0.0.1')) { Write-Host "   (ب) محلي — استخدم grant_contract_writer_system.ps1 عادي" }
    else {
      $t = "phx_probe_" + (Get-Random -Maximum 9999)
      $out = & schtasks /create /s $host_ /tn $t /tr "cmd.exe /c exit" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1
      if ($LASTEXITCODE -eq 0) {
        Write-Host "   ✓ (ب) أقدر أعمل مهمة SYSTEM عن بُعد → ينفع من هنا"
        & schtasks /delete /s $host_ /tn $t /f 2>&1 | Out-Null
      } else {
        Write-Host ("   ✗ (ب) مهمة عن بُعد مرفوضة: {0}" -f (($out | Select-Object -First 1) -replace '\s+',' '))
        Write-Host "   → لازم تدخل على سيرفر الفرع ده بنفسه"
      }
    }
  }
  Write-Host ""
}
