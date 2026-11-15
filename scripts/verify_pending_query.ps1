<#  verify_pending_query.ps1 - الاستعلام الكامل للطلبات المعلقة مقابل رد الـAPI

    الليه: الفلتر اتحدد اخيرا - sth_flag = 'P' يعني معلقة و'C' يعني مقفولة
    (55 مقابل 424,989). والدليل: فواتير 10 و13 نوفمبر لسه P وهي اللي الـAPI
    بيرجعها، وفواتير النهاردة بقت C بعد ما اتقفلت.

    السكربت بيبني الاستعلام الكامل اللي هيحل محل نداء الـAPI، وبيعرض عينة
    بكل الحقول عشان نقارنها بعين المجردة برد الـAPI قبل ما نبني المزامنة.

    قراءة بحتة بحساب phalix_reader.
#>
param([string]$Server = "localhost", [int]$Top = 5)
$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 72); Write-Host "  $t"; Write-Host ("=" * 72) }

$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Write-Host "مالقيتش $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null

function Q($sql, [int]$t = 60) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = $t
    $rd = $cmd.ExecuteReader()
    $cols=@(); for($i=0;$i -lt $rd.FieldCount;$i++){ $cols += $rd.GetName($i) }
    $rows=@(); while ($rd.Read()) { $o=[ordered]@{}; for($i=0;$i -lt $rd.FieldCount;$i++){ $o[$cols[$i]]=$rd.GetValue($i) }; $rows += [pscustomobject]$o }
    $rd.Close(); $sw.Stop(); return [pscustomobject]@{ rows=$rows; sec=$sw.Elapsed.TotalSeconds; err=$null }
  } catch { $sw.Stop(); return [pscustomobject]@{ rows=@(); sec=$sw.Elapsed.TotalSeconds; err=$_.Exception.Message } }
  finally { $c.Close() }
}

Head "1) اعمدة Customer (ندور على المنطقة والرصيد)"
$r = Q "SELECT c.name, t.name AS typ FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('Customer') AND (c.name LIKE '%region%' OR c.name LIKE '%balance%' OR c.name LIKE '%name%' OR c.name LIKE '%code%' OR c.name LIKE '%area%' OR c.name LIKE '%deliv%') ORDER BY c.colid"
$r.rows | ForEach-Object { "    {0,-26} {1}" -f $_.name, $_.typ }

Head "2) الاستعلام الكامل - اخر $Top طلبات معلقة"
$sql = @"
SELECT TOP $Top
  h.sth_id                AS bill_no,
  h.bill_typ,
  h.sth_flag              AS bill_status,
  h.delivery_date,
  h.sec_insert_date       AS bill_date,
  h.cust_id               AS cust_code,
  h.temp_col4             AS cust_name,
  h.no_of_items           AS count_of_items,
  h.total_bill_net,
  h.sth_extra_expenses    AS extra_expenses,
  h.sth_contract          AS contract,
  h.sth_notice            AS notes,
  h.sth_pc_name           AS computer,
  d.address               AS cust_address,
  d.tel                   AS cust_tel,
  d.contact,
  d.deliv_emp_id,
  emp.e_Name              AS employee_name,
  drv.e_Name              AS deliveryman
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d ON d.sth_id = h.sth_id
LEFT JOIN Employee emp       ON emp.e_id = h.emp_id
LEFT JOIN Employee drv       ON drv.e_id = d.deliv_emp_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
ORDER BY h.sth_id DESC
"@
$r = Q $sql
if ($r.err) {
  "  خطأ: $($r.err)"
  "  نجرب من غير Employee (ممكن اسم العمود مختلف)"
  $sql2 = $sql -replace "(?s)LEFT JOIN Employee.*?WHERE", "WHERE"
  $r = Q $sql2
  if ($r.err) { "  برضه فشل: $($r.err)" }
}
if (-not $r.err) {
  "  ({0:N2} ثانية، {1} صف)" -f $r.sec, $r.rows.Count
  foreach ($row in $r.rows) {
    Write-Host ""
    Write-Host "  ---- فاتورة $($row.bill_no) ----"
    $row.PSObject.Properties | ForEach-Object {
      $v = ("$($_.Value)" -replace "\s+"," "); if ($v.Length -gt 50) { $v = $v.Substring(0,50)+"..." }
      "      {0,-20} = {1}" -f $_.Name, $v
    }
  }
}

Head "3) العدد الاجمالي والزمن"
$r = Q "SELECT COUNT(*) AS n FROM sales_trans_h WHERE sth_delivery=1 AND sth_flag='P'"
if (-not $r.err) { "    طلبات معلقة: {0}   في {1:N2} ثانية" -f $r.rows[0].n, $r.sec }
Write-Host ""
Write-Host "    للمقارنة: نداء الـAPI لنفس البيانات بياخد 30 الى 90 ثانية."
Head "4) جدول Customer_Delivery (مصدر المنطقة غالبا)"
$r = Q "SELECT c.name, t.name AS typ FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('Customer_Delivery') ORDER BY c.colid"
if ($r.err) { "  مفيش الجدول ده: $($r.err)" } else { $r.rows | ForEach-Object { "    {0,-26} {1}" -f $_.name, $_.typ } }

Head "5) صف العميل 11787 من Customer و Customer_Delivery"
foreach ($tbl in @("Customer","Customer_Delivery")) {
  Write-Host ""
  Write-Host "  ---- $tbl ----"
  $r = Q "SELECT TOP 1 * FROM [$tbl] WHERE CAST(cust_id AS varchar(40)) = '11787'"
  if ($r.err) { "    خطأ: $($r.err)" }
  elseif ($r.rows.Count -eq 0) { "    مالقيتش صف" }
  else {
    $r.rows[0].PSObject.Properties | Where-Object { $_.Value -ne $null -and "$($_.Value)".Trim() -ne "" } | ForEach-Object {
      $v = ("$($_.Value)" -replace "\s+"," "); if ($v.Length -gt 55) { $v = $v.Substring(0,55)+"..." }
      "      {0,-26} = {1}" -f $_.Name, $v
    }
  }
}

Head "6) انواع الفواتير bill_typ"
$r = Q "SELECT TOP 10 bill_typ, COUNT(*) AS n FROM sales_trans_h WHERE sth_delivery=1 GROUP BY bill_typ ORDER BY n DESC"
if (-not $r.err) { $r.rows | ForEach-Object { "    bill_typ = {0}   {1}" -f $_.bill_typ, $_.n } }

Head "7) اعمدة Employee"
$r = Q "SELECT c.name, t.name AS typ FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('Employee') AND (c.name LIKE '%id%' OR c.name LIKE '%name%') ORDER BY c.colid"
if (-not $r.err) { $r.rows | ForEach-Object { "    {0,-26} {1}" -f $_.name, $_.typ } }