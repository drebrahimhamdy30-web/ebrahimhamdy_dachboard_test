# check_branches_contract.ps1
# يفحص كل فرع: بنوصله؟ العقود عنده على كام؟ وحساب الكتابة موجود؟
# **قراءة فقط** — مابيعملش حساب ولا بيعدّل أي رقم.
#
# بيقرا الفروع من إعدادات المزامنة (اللي فيها بيانات phalix_reader
# لكل فرع). الباسوردات مابتتطبعش.
#
# التشغيل على جهاز الماستر:  .\check_branches_contract.ps1

param(
  [string]$ConfigPath = "",
  [int]$OwnerCustId = 359
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# الإعدادات ممكن تكون في ProgramData (المزامنة) أو بروفايل المستخدم
# @() حوالين الناتج ضرورية: لو طلع مسار واحد بس، PowerShell بيرجّعه
# **نص** مش مصفوفة، و[0] ساعتها بيدي أول **حرف** ('C') مش أول عنصر.
$candidates = @(@(
  $ConfigPath,
  "C:\phalix\sync_engine.json",                    # ← مكانه الفعلي على الماستر
  "C:\ProgramData\phalix\sync_engine.json",
  "$env:USERPROFILE\.phalix\sync_engine.json",
  "C:\Windows\system32\config\systemprofile\.phalix\sync_engine.json"
) | Where-Object { $_ -and (Test-Path $_) })

if (-not $candidates) { Write-Host "مش لاقي ملف إعدادات المزامنة."; exit 1 }
$cfgPath = $candidates[0]
Write-Host "الإعدادات: $cfgPath`n"
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

$COLS = 'cc_local_items_disc'

foreach ($p in $cfg.branches.PSObject.Properties) {
  $name = $p.Name; $b = $p.Value
  Write-Host ("=== {0}  ({1})" -f $name, $b.server)

  # ١) بنوصل للسيرفر بحساب القراءة؟
  $cs = "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=10"
  try {
    $cn = New-Object System.Data.SqlClient.SqlConnection($cs); $cn.Open()
  } catch { Write-Host ("   ✗ مفيش وصول: {0}" -f $_.Exception.Message); Write-Host ""; continue }

  # ٢) العقود عنده على كام؟
  try {
    $c = $cn.CreateCommand()
    $c.CommandText = @"
SELECT cc_id, cc_name, cc_pay_perc, $COLS,
       CASE WHEN cc_pay_perc < 100
            THEN CAST($COLS * 100.0 / (100 - cc_pay_perc) AS decimal(9,1)) ELSE 0 END AS على_حصتها
  FROM Customer_Contracts
 WHERE cc_cust_id = $OwnerCustId AND cc_active = 1 AND cc_pay_perc < 100
 ORDER BY cc_id
"@
    $r = $c.ExecuteReader(); $found = $false
    while ($r.Read()) {
      $found = $true
      Write-Host ("   عقد {0,-3} {1,-18} المخزّن {2,6}  = {3,5}% على حصة الشركة" -f `
        $r['cc_id'], $r['cc_name'], $r[$COLS], $r['على_حصتها'])
    }
    $r.Close()
    if (-not $found) { Write-Host "   ⚠️ مفيش عقود للعميل $OwnerCustId هنا — الأرقام ممكن تكون مختلفة عندهم" }
  } catch { Write-Host ("   ✗ فشل قراءة العقود: {0}" -f $_.Exception.Message) }
  $cn.Close()

  # ٣) حساب الكتابة موجود؟
  try {
    $w = New-Object System.Data.SqlClient.SqlConnection(
      "Server=$($b.server);Database=Genius;User ID=phalix_writer;Password=$($env:PHX_WRITER_PWD);Connect Timeout=10")
    $w.Open(); $w.Close()
    Write-Host "   ✓ phalix_writer موجود وبيتصل — الفرع ده جاهز للتعديل"
  } catch {
    if ($env:PHX_WRITER_PWD) { Write-Host "   ✗ phalix_writer مش موجود/الباسورد مختلف → محتاج grant_contract_writer_system.ps1 على السيرفر ده" }
    else { Write-Host "   (لفحص حساب الكتابة: حط الباسورد في `$env:PHX_WRITER_PWD وشغّل تاني)" }
  }
  Write-Host ""
}

Write-Host "خلص الفحص. أي فرع عليه ✗ لحساب الكتابة لازم تدخل على سيرفره"
Write-Host "وتشغّل grant_contract_writer_system.ps1 محليًا (المهمة المجدولة"
Write-Host "كـSYSTEM مابتشتغلش عن بُعد)."
