<#  sync_pending_orders.ps1 - مزامنة طلبات التوصيل من SQL مباشرة بدل الـAPI

    الليه (2026-11-15): تطبيق eplus API بيتسلسل - أول نداء استنى 134 ثانية
    واللي بعده رجع فورا. بينفذ طلب تقيل واحد في المرة والباقي في طابور،
    وبأربع فروع بينادوه كل دقيقتين بيختنق وشاشة التوزيع تقف. حصل النهاردة
    وفضل ساعات. القراءة المباشرة 0.14 ثانية مقابل 30-90 ثانية.

    خريطة اتأكدت حقل بحقل مقابل رد الـAPI الفعلي:
      bill_no = sth_id · bill_status = sth_flag ('P' معلقة) · cust_code = cust_id
      customer_name = temp_col4 · count_of_items = no_of_items · notes = sth_notice
      total_bill_net = total_bill_net (6 من 7 فواتير مطابقة؛ السابعة اتعدلت
        بعد ما الـAPI قراها - sec_update_date يثبت ده)
      العنوان/التليفون = sales_deliv_info · المنطقة = dc_region_name_ar
      الرصيد = cust_current_credit (6279.9950 مطابق للـAPI)
      bill_typ: 1=كاش · 2=آجل (اتأكد بـ3 فواتير) · 3=فيزا

    أمان الكتابة: الطلب الجديد يتدرج كامل بحالة pending. الطلب الموجود
    يتحدث في حقول البيانات بس - من غير status ولا driver_id ولا deliveryman،
    عشان طلب متوزع على طيار ما يترجعش pending ويضيع التوزيع.

    الاستخدام:
      .\scripts\sync_pending_orders.ps1            عرض فقط
      .\scripts\sync_pending_orders.ps1 -Apply     يكتب
      .\scripts\sync_pending_orders.ps1 -Install -Apply   مهمة كل دقيقة
      .\scripts\sync_pending_orders.ps1 -Uninstall
#>
param(
  [switch]$Apply,
  [switch]$Install,
  [switch]$Uninstall,
  [string]$BranchId = "f13f20f2-9847-4c16-9946-668769f7ed20",
  [string]$Server   = "localhost",
  [int]$Show        = 2
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TaskName = "Phalix - sync pending orders"
$LogDir   = "C:\phalix\logs"
$LogFile  = Join-Path $LogDir "sync_pending_orders.log"

function Log([string]$m) {
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}
function Head($t){ Write-Host ""; Write-Host ("=" * 70); Write-Host "  $t"; Write-Host ("=" * 70) }

if ($Uninstall) {
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Log "اتشالت المهمة" }
  catch { Log "مفيش مهمة بالاسم ده" }
  return
}
if ($Install) {
  $self = $MyInvocation.MyCommand.Path
  Write-Host "المهمة: $TaskName   كل دقيقة   SYSTEM"
  Write-Host "الملف : $self"
  if (-not $Apply) { Write-Host ""; Write-Host "عرض فقط. للتنفيذ: -Install -Apply"; return }
  try {
    $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$self`" -Apply"
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t -Settings $s -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    Log "اتسجلت المهمة: $TaskName"
  } catch { Log "فشل التسجيل: $($_.Exception.Message)" }
  return
}

# ---------- eplus ----------
$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Log "مالقيتش $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null

# ملحوظة: لو العميل عنده اكتر من عنوان، نفضل العنوان اللي ليه منطقة
$SQL = @"
SELECT
  h.sth_id AS bill_no, h.bill_typ, h.sec_insert_date AS bill_date,
  h.cust_id AS cust_code, h.temp_col4 AS customer_name,
  d.address AS customer_address, d.tel AS customer_phone,
  dcr.dc_region_name_ar AS cust_region,
  h.no_of_items AS count_of_items, h.sth_notice AS notes,
  emp.e_Name AS employee_name, h.total_bill_net,
  c.cust_current_credit AS current_customer_balance,
  h.sth_extra_expenses AS additional_expenses
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d ON d.sth_id = h.sth_id
LEFT JOIN Customer c         ON c.cust_id = h.cust_id
LEFT JOIN Customer_Delivery cd
       ON cd.cd_cust_id = h.cust_id
      AND cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x
                       WHERE x.cd_cust_id = h.cust_id
                         AND (x.cd_region_id > 0 OR NOT EXISTS
                              (SELECT 1 FROM Customer_Delivery y
                                WHERE y.cd_cust_id = h.cust_id AND y.cd_region_id > 0)))
LEFT JOIN Delivery_cost_region dcr ON dcr.dc_id = cd.cd_region_id
LEFT JOIN Employee emp             ON emp.e_id = h.emp_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
ORDER BY h.sth_id DESC
"@

function Q($sql, [int]$t = 60) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  $sw=[Diagnostics.Stopwatch]::StartNew()
  try {
    $c.Open(); $cmd=$c.CreateCommand(); $cmd.CommandText=$sql; $cmd.CommandTimeout=$t
    $rd=$cmd.ExecuteReader(); $cols=@(); for($i=0;$i -lt $rd.FieldCount;$i++){ $cols+=$rd.GetName($i) }
    $rows=@(); while($rd.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $rd.FieldCount;$i++){ $v=$rd.GetValue($i); $o[$cols[$i]]=$(if($v -is [DBNull]){$null}else{$v}) }; $rows+=[pscustomobject]$o }
    $rd.Close(); $sw.Stop(); return [pscustomobject]@{ rows=$rows; sec=$sw.Elapsed.TotalSeconds; err=$null }
  } catch { $sw.Stop(); return [pscustomobject]@{ rows=@(); sec=$sw.Elapsed.TotalSeconds; err=$_.Exception.Message } }
  finally { $c.Close() }
}

$RunStart  = Get-Date
$RunNew    = 0
$RunUpd    = 0
$RunStatus = "ok"
$RunError  = $null

Head "1) قراءة من eplus"
$res = Q $SQL
if ($res.err) { Log "فشل القراءة: $($res.err)"; $RunStatus="error"; $RunError=$res.err; Write-SyncRun; return }
Log ("قرأ {0} طلب معلق في {1:N2} ثانية" -f $res.rows.Count, $res.sec)
if ($res.rows.Count -eq 0) { Log "مفيش طلبات معلقة"; return }

$TYPE = @{ 1 = "كاش"; 2 = "آجل"; 3 = "فيزا" }
function Clean-Phone($v) {
  if (-not $v) { return $null }
  $p = ([string]$v) -split '[^0-9]+' | Where-Object { $_.Length -ge 7 }
  if ($p.Count -eq 0) { return $null }
  return ($p -join ', ')
}

$rowsOut = @()
$unknownType = @{}
foreach ($r in $res.rows) {
  $bt = $TYPE[[int]$r.bill_typ]
  if (-not $bt) { $bt = "كاش"; $unknownType[[string]$r.bill_typ] = $true }
  $rowsOut += [ordered]@{
    bill_no                  = [string]$r.bill_no
    bill_type                = $bt
    bill_date                = $(if ($r.bill_date) { ([datetime]$r.bill_date).ToString("yyyy-MM-dd HH:mm:ss") } else { $null })
    cust_code                = [string]$r.cust_code
    customer_name            = $r.customer_name
    customer_address         = $r.customer_address
    customer_phone           = Clean-Phone $r.customer_phone
    cust_region              = $(if ($r.cust_region -and ([string]$r.cust_region).Trim()) { ([string]$r.cust_region).Trim() } else { "يحتاج إضافة منطقة" })
    count_of_items           = $(if ($r.count_of_items -ne $null) { [int]$r.count_of_items } else { $null })
    notes                    = $r.notes
    employee_name            = $r.employee_name
    total_bill_net           = $(if ($r.total_bill_net -ne $null) { [double]$r.total_bill_net } else { $null })
    current_customer_balance = $(if ($r.current_customer_balance -ne $null) { [double]$r.current_customer_balance } else { $null })
    bill_status              = "Pending"
    additional_expenses      = $(if ($r.additional_expenses -ne $null) { [double]$r.additional_expenses } else { 0 })
  }
}
if ($unknownType.Count) { Log ("تحذير: bill_typ مش معروف -> " + (($unknownType.Keys) -join ", ") + " (اتخزنت كاش)") }
$noReg = ($rowsOut | Where-Object { $_.cust_region -eq "يحتاج إضافة منطقة" }).Count
Log ("بلا منطقة: {0} من {1}" -f $noReg, $rowsOut.Count)

Head "2) عينة ($Show)"
$rowsOut | Select-Object -First $Show | ForEach-Object {
  Write-Host ""
  $_.GetEnumerator() | ForEach-Object {
    $v = ("$($_.Value)" -replace "\s+"," "); if ($v.Length -gt 46) { $v = $v.Substring(0,46)+"..." }
    "    {0,-26} = {1}" -f $_.Key, $v
  }
}

# ---------- Supabase ----------
$cfgPath = "C:\phalix\sync_engine.json"
if (-not (Test-Path $cfgPath)) { Log "مالقيتش $cfgPath"; return }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$SB  = $cfg.supabaseUrl.TrimEnd('/')
$KEY = $cfg.serviceKey
if (-not $SB -or -not $KEY) { Log "الاعدادات ناقصة في $cfgPath"; return }

$H = @{ apikey = $KEY; Authorization = "Bearer $KEY" }
function SbGet($path) {
  try { return Invoke-RestMethod -Uri "$SB/rest/v1/$path" -Headers $H -Method GET -TimeoutSec 60 }
  catch { Log "GET فشل: $($_.Exception.Message)"; return $null }
}
function SbSend($path, $obj, $prefer) {
  $script:LastPostOk = $true
  $json  = $obj | ConvertTo-Json -Depth 6 -Compress
  if ($obj -isnot [array]) { $json = "[$json]" }
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $h2 = $H.Clone(); $h2["Content-Type"] = "application/json; charset=utf-8"; $h2["Prefer"] = $prefer
  try { return Invoke-RestMethod -Uri "$SB/rest/v1/$path" -Headers $h2 -Method POST -Body $bytes -TimeoutSec 90 }
  catch {
    $d = ""
    if ($_.Exception.Response) { try { $d = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {} }
    Log "POST فشل: $($_.Exception.Message) $d"
    $script:LastPostOk = $false
    return $null
  }
}

# تسجيل التشغيل في مركز المزامنة - من غيره المهمة شغالة بس خفية عن الشاشة
function Write-SyncRun {
  if (-not $Apply) { return }
  $ms = [int]((Get-Date) - $RunStart).TotalMilliseconds
  $row = [pscustomobject]@{
    job_id      = "delivery_orders"
    branch      = "mamora"
    kind        = "orders"
    new_rows    = $RunNew
    item_rows   = $RunUpd
    duration_ms = $ms
    status      = $RunStatus
    error       = $RunError
  }
  $null = SbSend "sync_runs" @($row) "return=minimal"
  $patch = @{ last_run_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); last_status = $RunStatus } | ConvertTo-Json -Compress
  try {
    $h2 = $H.Clone(); $h2["Content-Type"] = "application/json; charset=utf-8"; $h2["Prefer"] = "return=minimal"
    Invoke-RestMethod -Uri "$SB/rest/v1/sync_jobs?id=eq.delivery_orders" -Headers $h2 -Method PATCH -Body ([Text.Encoding]::UTF8.GetBytes($patch)) -TimeoutSec 30 | Out-Null
  } catch { Log "تحديث sync_jobs فشل: $($_.Exception.Message)" }
}

Head "3) مقارنة بالموجود"
$bills   = $rowsOut | ForEach-Object { $_.bill_no }
$inList  = "(" + ($bills -join ",") + ")"
$existing = SbGet ("orders?select=bill_no&bill_no=in." + $inList)
$exSet = @{}; if ($existing) { $existing | ForEach-Object { $exSet[[string]$_.bill_no] = $true } }
$newRows = @($rowsOut | Where-Object { -not $exSet.ContainsKey($_.bill_no) })
$updRows = @($rowsOut | Where-Object { $exSet.ContainsKey($_.bill_no) })
Log ("جديد: {0}   موجود هيتحدث: {1}" -f $newRows.Count, $updRows.Count)

if (-not $Apply) {
  Head "الخلاصة"
  Write-Host "  عرض فقط - ماتكتبش حاجة. للتنفيذ: -Apply"
  return
}

Head "4) الكتابة"
# الجديد: ادراج كامل بحالة pending
if ($newRows.Count) {
  $ins = $newRows | ForEach-Object {
    $o = [ordered]@{}; $_.GetEnumerator() | ForEach-Object { $o[$_.Key] = $_.Value }
    $o["branch_id"] = $BranchId; $o["driver_id"] = $null; $o["deliveryman"] = $null; $o["status"] = "pending"
    [pscustomobject]$o
  }
  $created = SbSend "orders?on_conflict=bill_no" @($ins) "resolution=merge-duplicates,return=representation"
  if (-not $script:LastPostOk) { Log "فشل ادراج الطلبات الجديدة" }
  if ($created) {
    Log ("اتدرج {0} طلب جديد" -f @($created).Count); $RunNew = @($created).Count
    $logs = @($created) | ForEach-Object {
      [pscustomobject]@{
        order_id  = $_.id
        event     = "order_created"
        details   = @{ source = "مزامنة مباشرة من eplus"; bill_no = $_.bill_no; amount = $_.total_bill_net; region = $_.cust_region }
        user_name = "المزامنة"
      }
    }
    if ($logs.Count) {
      $null = SbSend "order_logs" @($logs) "return=minimal"
      if ($script:LastPostOk) { Log ("اتسجل {0} سطر في order_logs" -f $logs.Count) }
      else { Log "تحذير: الطلبات اتدرجت بس order_logs فشل - الطلبات سليمة والسجل بس هو الناقص" }
    }
  }
} else { Log "مفيش طلبات جديدة" }

# الموجود: تحديث حقول البيانات بس - من غير status/driver_id/deliveryman
if ($updRows.Count) {
  $upd = $updRows | ForEach-Object {
    $o = [ordered]@{}
    $_.GetEnumerator() | Where-Object { $_.Key -ne "customer_phone" -or ($_.Value -and $_.Value.Trim()) } | ForEach-Object { $o[$_.Key] = $_.Value }
    [pscustomobject]$o
  }
  $null = SbSend "orders?on_conflict=bill_no" @($upd) "resolution=merge-duplicates,return=minimal"
  if ($script:LastPostOk) { Log ("اتحدث {0} طلب موجود (بدون المساس بالتوزيع)" -f $updRows.Count); $RunUpd = $updRows.Count }
  else { Log ("فشل تحديث {0} طلب موجود" -f $updRows.Count); $RunStatus="error"; $RunError="فشل تحديث الطلبات الموجودة" }
} else { Log "مفيش طلبات تتحدث" }

Write-SyncRun
Log ("خلصت - جديد {0} / محدّث {1} / {2}" -f $RunNew, $RunUpd, $RunStatus)