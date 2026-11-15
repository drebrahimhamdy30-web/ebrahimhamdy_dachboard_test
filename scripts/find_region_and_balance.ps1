<#  find_region_and_balance.ps1 - آخر حقلين ناقصين

    الليه: الاستعلام البديل للـAPI اشتغل (57 طلب في 0.00 ثانية مقابل 30-90
    ثانية للـAPI) وكل الحقول اتربطت ما عدا اتنين:

    1) cust_region: الـAPI بيرجع "الأسكندرية - ابو قير - مربع الشرطه"
       والشاشة بتاخد الجزء التالت لتوزيع الطيارين. Customer.cust_region_id
       طلع 0 للعميل اللي فحصناه، وCustomer_Delivery مفتاحه cd_cust_id مش
       cust_id وفيه cd_region_id - فالمنطقة على الأرجح في السلسلة دي.

    2) current_customer_balance: Customer.cust_current_credit رجع 0 لعميل
       الـAPI رجعله 0 كمان - متطابق بس محتاج تأكيد بعميل رصيده مش صفر.
       العميل 15010 (بلال ياسر) الـAPI رجعله 6279.995.

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

Head "1) الجداول اللي اسمها فيه region او area او city"
$r = Q "SELECT name FROM sysobjects WHERE xtype='U' AND (name LIKE '%region%' OR name LIKE '%area%' OR name LIKE '%city%' OR name LIKE '%gov%') ORDER BY name"
$r.rows | ForEach-Object { "    $($_.name)" }

Head "2) اعمدة كل جدول منطقة + عينة صفوف"
foreach ($t in ($r.rows | ForEach-Object { $_.name })) {
  Write-Host ""
  Write-Host "  ---- $t ----"
  $c = Q "SELECT c.name, ty.name AS typ FROM syscolumns c JOIN systypes ty ON ty.xtype=c.xtype WHERE c.id=OBJECT_ID('$t') ORDER BY c.colid"
  "    الاعمدة: " + (($c.rows | ForEach-Object { $_.name }) -join ", ")
  $s = Q "SELECT TOP 3 * FROM [$t]"
  if ($s.rows.Count) { $s.rows | Format-Table -AutoSize | Out-String | Write-Host }
}

Head "3) Customer_Delivery للعميل 11787 (المفتاح cd_cust_id)"
$r = Q "SELECT TOP 3 * FROM Customer_Delivery WHERE cd_cust_id = 11787"
if ($r.err) { "    خطأ: $($r.err)" }
elseif ($r.rows.Count -eq 0) { "    مفيش صف" }
else { $r.rows | Format-Table -AutoSize | Out-String | Write-Host }

Head "4) تأكيد الرصيد - العميل 15010 (الـAPI رجعله 6279.995)"
$r = Q "SELECT cust_id, cust_code, cust_name_ar, cust_current_credit, cust_start_credit, cust_start_debit, cust_max_credit FROM Customer WHERE cust_code = '15010'"
if ($r.err) { "    خطأ: $($r.err)" } else { $r.rows | Format-Table -AutoSize | Out-String | Write-Host }

Head "5) المنطقة لفاتورة حقيقية - 1513172 (الـAPI: عزبة نشات)"
$r = Q @"
SELECT TOP 3 h.sth_id, h.cust_id, cd.cd_id, cd.cd_region_id, cd.cd_address, c.cust_region_id, c.cust_dc_region_id
FROM sales_trans_h h
LEFT JOIN Customer c ON c.cust_id = h.cust_id
LEFT JOIN Customer_Delivery cd ON cd.cd_cust_id = h.cust_id
WHERE CAST(h.sth_id AS varchar(40)) = '1513172'
"@
if ($r.err) { "    خطأ: $($r.err)" } else { $r.rows | Format-Table -AutoSize | Out-String | Write-Host }

Head "6) هل sales_deliv_info فيه عمود منطقة؟"
$r = Q "SELECT c.name, ty.name AS typ FROM syscolumns c JOIN systypes ty ON ty.xtype=c.xtype WHERE c.id=OBJECT_ID('sales_deliv_info') ORDER BY c.colid"
"    " + (($r.rows | ForEach-Object { $_.name }) -join ", ")