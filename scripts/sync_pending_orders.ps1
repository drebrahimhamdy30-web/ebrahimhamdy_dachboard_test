<#  sync_pending_orders.ps1 - جلب الطلبات المعلقة من SQL مباشرة بدل الـAPI

    الليه (2026-11-15): تطبيق eplus API بيتسلسل - أول نداء استنى 134 ثانية
    والنداءات بعده رجعت فورا. يعني بينفذ طلب تقيل واحد في المرة والباقي
    في طابور. وبأربع فروع بينادوه كل دقيقتين، الطلب بيتجاوز طاقته فيختنق
    وشاشة التوزيع تقف. حصل النهاردة وفضل ساعات.

    القراءة المباشرة من SQL أسرع بمئات المرات ومستقلة عن التطبيق تماما:
      57 طلب معلق  ->  0.00 ثانية        (نفسها من الـAPI: 30-90 ثانية)
      الاستعلام كامل -> 0.15 ثانية
    ومهام المزامنة التانية (cashier_txns/shifts/safes) اللي بتقرا SQL
    مباشرة فضلت شغالة كل دقيقة وقت ما الـAPI كان ميت - فالطريقة مجربة.

    خريطة الحقول (اتأكدت حقل بحقل مقابل رد الـAPI):
      bill_no              = sales_trans_h.sth_id
      bill_status          = sth_flag         'P' معلقة / 'C' مقفولة
      bill_date            = sec_insert_date
      cust_code            = cust_id
      customer_name        = temp_col4
      count_of_items       = no_of_items
      notes                = sth_notice
      total_bill_net       = total_bill_net
      additional_expenses  = sth_extra_expenses
      customer_address     = sales_deliv_info.address
      customer_phone       = sales_deliv_info.tel
      employee_name        = Employee.e_Name عبر emp_id
      cust_region          = Delivery_cost_region.dc_region_name_ar
                             عبر Customer_Delivery.cd_region_id
      current_customer_balance = Customer.cust_current_credit

    الاستخدام:
      .\scripts\sync_pending_orders.ps1          عرض فقط - مابيكتبش
      .\scripts\sync_pending_orders.ps1 -Apply   يكتب في Supabase
#>
param(
  [switch]$Apply,
  [string]$BranchId = "f13f20f2-9847-4c16-9946-668769f7ed20",
  [string]$Server   = "localhost",
  [int]$Show        = 3
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Head($t){ Write-Host ""; Write-Host ("=" * 72); Write-Host "  $t"; Write-Host ("=" * 72) }

# ---------- 1) قراءة eplus ----------
$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Write-Host "مالقيتش $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null

$SQL = @"
SELECT
  h.sth_id              AS bill_no,
  h.bill_typ            AS bill_typ,
  h.sec_insert_date     AS bill_date,
  h.cust_id             AS cust_code,
  h.temp_col4           AS customer_name,
  d.address             AS customer_address,
  d.tel                 AS customer_phone,
  dcr.dc_region_name_ar AS cust_region,
  h.no_of_items         AS count_of_items,
  h.sth_notice          AS notes,
  emp.e_Name            AS employee_name,
  h.total_bill_net      AS total_bill_net,
  c.cust_current_credit AS current_customer_balance,
  h.sth_extra_expenses  AS additional_expenses
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d ON d.sth_id = h.sth_id
LEFT JOIN Customer c         ON c.cust_id = h.cust_id
LEFT JOIN Customer_Delivery cd
       ON cd.cd_cust_id = h.cust_id
      AND cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id)
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
    $rows=@(); while($rd.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $rd.FieldCount;$i++){ $v=$rd.GetValue($i); $o[$cols[$i]] = $(if ($v -is [DBNull]) { $null } else { $v }) }; $rows+=[pscustomobject]$o }
    $rd.Close(); $sw.Stop(); return [pscustomobject]@{ rows=$rows; sec=$sw.Elapsed.TotalSeconds; err=$null }
  } catch { $sw.Stop(); return [pscustomobject]@{ rows=@(); sec=$sw.Elapsed.TotalSeconds; err=$_.Exception.Message } }
  finally { $c.Close() }
}

Head "1) قراءة الطلبات المعلقة من eplus"
$res = Q $SQL
if ($res.err) { Write-Host "  فشل: $($res.err)"; return }
Write-Host ("  {0} طلب معلق في {1:N2} ثانية" -f $res.rows.Count, $res.sec)
if ($res.rows.Count -eq 0) { Write-Host "  مفيش طلبات معلقة"; return }

Head "2) تأكيد خريطة bill_typ"
# عينات معروفة من قاعدتنا: هدول اتخزنوا بـ'آجل'
$known = @{ "1513667"="آجل"; "1513630"="آجل"; "1513571"="آجل" }
$chk = Q ("SELECT CAST(sth_id AS varchar(40)) AS b, bill_typ FROM sales_trans_h WHERE CAST(sth_id AS varchar(40)) IN ('" + (($known.Keys) -join "','") + "')")
foreach ($r in $chk.rows) { "    فاتورة {0}  bill_typ={1}   عندنا متخزنة = {2}" -f $r.b, $r.bill_typ, $known[$r.b] }
Write-Host "    (1 = كاش مؤكد من 410,688 فاتورة)"

$TYPE = @{ 1 = "كاش"; 2 = "فيزا"; 3 = "آجل" }

# ---------- 3) تحويل للشكل اللي بيتخزن ----------
function Clean-Phone($v) {
  if (-not $v) { return $null }
  $parts = ([string]$v) -split '[^0-9]+' | Where-Object { $_.Length -ge 7 }
  if ($parts.Count -eq 0) { return $null }
  return ($parts -join ', ')
}

$payload = @()
foreach ($r in $res.rows) {
  $bt = $TYPE[[int]$r.bill_typ]; if (-not $bt) { $bt = "كاش" }
  $payload += [ordered]@{
    bill_no                  = [string]$r.bill_no
    bill_type                = $bt
    bill_date                = $(if ($r.bill_date) { ([datetime]$r.bill_date).ToString("yyyy-MM-dd HH:mm:ss") } else { $null })
    cust_code                = [string]$r.cust_code
    customer_name            = $r.customer_name
    customer_address         = $r.customer_address
    customer_phone           = Clean-Phone $r.customer_phone
    cust_region              = $(if ($r.cust_region) { ([string]$r.cust_region).Trim() } else { "يحتاج إضافة منطقة" })
    count_of_items           = $(if ($r.count_of_items -ne $null) { [int]$r.count_of_items } else { $null })
    notes                    = $r.notes
    deliveryman              = $null
    employee_name            = $r.employee_name
    total_bill_net           = $(if ($r.total_bill_net -ne $null) { [double]$r.total_bill_net } else { $null })
    current_customer_balance = $(if ($r.current_customer_balance -ne $null) { [double]$r.current_customer_balance } else { $null })
    bill_status              = "Pending"
    additional_expenses      = $(if ($r.additional_expenses -ne $null) { [double]$r.additional_expenses } else { 0 })
    branch_id                = $BranchId
    driver_id                = $null
    status                   = "pending"
  }
}

Head "3) عينة من اللي هيتخزن ($Show من $($payload.Count))"
$payload | Select-Object -First $Show | ForEach-Object {
  Write-Host ""
  $_.GetEnumerator() | ForEach-Object {
    $v = ("$($_.Value)" -replace "\s+"," "); if ($v.Length -gt 48) { $v = $v.Substring(0,48)+"..." }
    "    {0,-26} = {1}" -f $_.Key, $v
  }
}
$noRegion = ($payload | Where-Object { $_.cust_region -eq "يحتاج إضافة منطقة" }).Count
Write-Host ""
Write-Host ("  بلا منطقة: {0} من {1}" -f $noRegion, $payload.Count)

# ---------- 4) إعدادات Supabase ----------
Head "4) إعدادات Supabase"
$cfgPath = "C:\phalix\sync_engine.json"
if (-not (Test-Path $cfgPath)) { Write-Host "  مالقيتش $cfgPath"; }
else {
  $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
  $keys = $cfg.PSObject.Properties | ForEach-Object { $_.Name }
  "  مفاتيح الملف: " + ($keys -join ", ")
  $urlKey = $keys | Where-Object { $_ -match 'supabase.*url|url' } | Select-Object -First 1
  $keyKey = $keys | Where-Object { $_ -match 'service|key|token' }  | Select-Object -First 1
  if ($urlKey) { "  عنوان Supabase : $($cfg.$urlKey)" } else { "  ⚠️ مالقيتش مفتاح العنوان" }
  if ($keyKey) { "  مفتاح الكتابة  : موجود باسم '$keyKey' (مش هيتطبع)" } else { "  ⚠️ مالقيتش مفتاح الكتابة" }
}

Head "الخلاصة"
if (-not $Apply) {
  Write-Host "  عرض فقط - ماتكتبش حاجة."
  Write-Host "  راجع العينة فوق وقارنها برد الـAPI، وبعدين شغل بـ-Apply."
} else {
  Write-Host "  -Apply لسه مش مفعّل في النسخة دي - الكتابة هتتضاف بعد مراجعة العينة."
}