<#  final_region_check.ps1 - تأكيد سلسلة المنطقة + الاستعلام النهائي الكامل

    الليه: الرصيد اتأكد (cust_current_credit = 6279.9950 مطابق للـAPI).
    والمنطقة: cd_region_id = 63 لفاتورة الـAPI قال عنها
    "الأسكندرية - ابو قير - عزبة نشات". وDelivery_cost_region فيه
    dc_region_name_ar وdc_governorate_id=3 اللي هو الأسكندرية في جدول
    governorates - فالسلسلة على الأرجح:
      cd_region_id -> Delivery_cost_region.dc_id -> dc_region_name_ar
      + dc_governorate_id -> governorates.governorate_name_ar
      + dc_city_id -> المدينة (ابو قير)

    السكربت بيتأكد من الحلقة دي وبيطبع الاستعلام النهائي الكامل بالمنطقة
    والرصيد عشان نقارنه برد الـAPI حقل بحقل قبل بناء المزامنة.

    قراءة بحتة بحساب phalix_reader.
#>
param([string]$Server = "localhost")
$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 72); Write-Host "  $t"; Write-Host ("=" * 72) }
$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Write-Host "مالقيتش $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null
function Q($sql, [int]$t = 60) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  $sw=[Diagnostics.Stopwatch]::StartNew()
  try {
    $c.Open(); $cmd=$c.CreateCommand(); $cmd.CommandText=$sql; $cmd.CommandTimeout=$t
    $rd=$cmd.ExecuteReader(); $cols=@(); for($i=0;$i -lt $rd.FieldCount;$i++){ $cols+=$rd.GetName($i) }
    $rows=@(); while($rd.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $rd.FieldCount;$i++){ $o[$cols[$i]]=$rd.GetValue($i) }; $rows+=[pscustomobject]$o }
    $rd.Close(); $sw.Stop(); return [pscustomobject]@{ rows=$rows; sec=$sw.Elapsed.TotalSeconds; err=$null }
  } catch { $sw.Stop(); return [pscustomobject]@{ rows=@(); sec=$sw.Elapsed.TotalSeconds; err=$_.Exception.Message } }
  finally { $c.Close() }
}

Head "1) Delivery_cost_region للمعرف 63"
$r = Q "SELECT * FROM Delivery_cost_region WHERE dc_id = 63"
if ($r.err) { "  خطأ: $($r.err)" } elseif (-not $r.rows.Count) { "  مفيش صف بـdc_id=63" }
else { $r.rows[0].PSObject.Properties | ForEach-Object { "    {0,-24} = {1}" -f $_.Name, $_.Value } }

Head "2) Regions للمعرفات 63 و 93"
$r = Q "SELECT r_id, r_name_ar, r_parent FROM Regions WHERE r_id IN (63,93)"
if ($r.err) { "  خطأ: $($r.err)" } elseif (-not $r.rows.Count) { "  جدول Regions فاضي او مفيش المعرفات دي" }
else { $r.rows | Format-Table -AutoSize | Out-String | Write-Host }
$r = Q "SELECT COUNT(*) AS n FROM Regions"
"    اجمالي صفوف Regions: $(if($r.rows.Count){$r.rows[0].n}else{'?'})"

Head "3) الاستعلام النهائي الكامل - 3 طلبات معلقة"
$sql = @"
SELECT TOP 3
  h.sth_id              AS bill_no,
  h.bill_typ,
  h.sth_flag            AS bill_status,
  h.sec_insert_date     AS bill_date,
  h.cust_id             AS cust_code,
  h.temp_col4           AS customer_name,
  d.address             AS customer_address,
  d.tel                 AS customer_phone,
  ISNULL(g.governorate_name_ar,'') + ' - ' + ISNULL(dcr.dc_region_name_ar,'') AS cust_region,
  cd.cd_region_id,
  h.no_of_items         AS count_of_items,
  h.sth_notice          AS notes,
  emp.e_Name            AS employee_name,
  drv.e_Name            AS deliveryman,
  h.total_bill_net,
  c.cust_current_credit AS current_customer_balance,
  h.sth_extra_expenses  AS additional_expenses,
  h.sth_contract        AS contract
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d      ON d.sth_id = h.sth_id
LEFT JOIN Customer c              ON c.cust_id = h.cust_id
LEFT JOIN Customer_Delivery cd    ON cd.cd_cust_id = h.cust_id
LEFT JOIN Delivery_cost_region dcr ON dcr.dc_id = cd.cd_region_id
LEFT JOIN governorates g          ON g.id = dcr.dc_governorate_id
LEFT JOIN Employee emp            ON emp.e_id = h.emp_id
LEFT JOIN Employee drv            ON drv.e_id = d.deliv_emp_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
ORDER BY h.sth_id DESC
"@
$r = Q $sql
if ($r.err) { "  خطأ: $($r.err)" }
else {
  "  ({0:N2} ثانية)" -f $r.sec
  foreach ($row in $r.rows) {
    Write-Host ""
    Write-Host "  ---- $($row.bill_no) ----"
    $row.PSObject.Properties | ForEach-Object {
      $v = ("$($_.Value)" -replace "\s+"," "); if ($v.Length -gt 50) { $v = $v.Substring(0,50)+"..." }
      "      {0,-26} = {1}" -f $_.Name, $v
    }
  }
}