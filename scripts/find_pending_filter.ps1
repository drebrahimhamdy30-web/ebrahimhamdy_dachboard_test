<#  find_pending_filter.ps1 - ايه الفلتر اللي يساوي Pending بتاع الـAPI؟

    الليه: الـAPI بيرجع 60 فاتورة معلقة للمعمورة. الفلتر المتوقع
    (sth_delivery=1 AND sth_deliv_closed=0) رجع 425,021 صف - يعني العمود
    ده شبه مهجور وكل الفواتير فيه False.

    مرشحين أفضل اتلاحظوا من الصف الكامل:
      - sth_dc_closed (smalldatetime) كان فاضي في فاتورة معلقة
      - جدول sales_deliv_close فيه sdc_bill_no = سجل الاقفال، فالمعلق
        هو اللي مش موجود فيه
      - sth_flag (char) قيمته C

    السكربت بيجرب كل الاحتمالات ويقارن بـ60. قراءة بحتة.
#>
param([string]$Server = "localhost", [int]$Target = 60)
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

Head "1) جدول sales_deliv_close"
$r = Q "SELECT c.name, t.name AS typ FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('sales_deliv_close') ORDER BY c.colid"
$r.rows | ForEach-Object { "    {0,-24} {1}" -f $_.name, $_.typ }
$r = Q "SELECT COUNT(*) AS n FROM sales_deliv_close"
"    عدد صفوفه: $(if($r.rows.Count){$r.rows[0].n}else{'?'})"

Head "2) قيم sth_flag"
$r = Q "SELECT TOP 10 sth_flag, COUNT(*) AS n FROM sales_trans_h WHERE sth_delivery=1 GROUP BY sth_flag ORDER BY n DESC"
if ($r.err) { "  خطأ: $($r.err)" } else { $r.rows | ForEach-Object { "    sth_flag = '{0}'   {1}" -f $_.sth_flag, $_.n } }

Head "3) اختبار الفلاتر — الهدف قريب من $Target"
$tests = @(
  @("sth_delivery=1 AND sth_dc_closed IS NULL", "dc_closed فاضي"),
  @("sth_delivery=1 AND sth_dc_closed IS NULL AND sec_insert_date > DATEADD(day,-30,GETDATE())", "dc_closed فاضي + 30 يوم"),
  @("sth_delivery=1 AND sth_id NOT IN (SELECT sdc_bill_no FROM sales_deliv_close)", "مش في سجل الاقفال"),
  @("sth_delivery=1 AND sec_insert_date > DATEADD(day,-30,GETDATE()) AND sth_id NOT IN (SELECT sdc_bill_no FROM sales_deliv_close)", "مش مقفول + 30 يوم"),
  @("sth_delivery=1 AND sth_deliv_closed=0 AND sec_insert_date > DATEADD(day,-30,GETDATE())", "deliv_closed=0 + 30 يوم"),
  @("sth_delivery=1 AND sth_deliv_closed=0 AND sec_insert_date > DATEADD(day,-10,GETDATE())", "deliv_closed=0 + 10 ايام")
)
foreach ($t in $tests) {
  $r = Q "SELECT COUNT(*) AS n FROM sales_trans_h WHERE $($t[0])"
  if ($r.err) { "    {0,-34} خطأ: {1}" -f $t[1], ($r.err -replace "\s+"," ").Substring(0,[Math]::Min(70,$r.err.Length)) }
  else {
    $n = $r.rows[0].n
    $mark = if ([Math]::Abs($n - $Target) -le 15) { "  <<< قريب من الهدف" } else { "" }
    "    {0,-34} = {1,8}   ({2:N2}ث){3}" -f $t[1], $n, $r.sec, $mark
  }
}

Head "4) الفواتير اللي الـAPI رجعها - هل مقفولة ولا لأ؟"
$sample = "'1509513','1511969','1513999','1514068'"
$r = Q "SELECT sth_id, sth_deliv_closed, sth_dc_closed, sth_flag, sec_insert_date, CASE WHEN sth_id IN (SELECT sdc_bill_no FROM sales_deliv_close) THEN 'في سجل الاقفال' ELSE 'مش فيه' END AS closed_log FROM sales_trans_h WHERE CAST(sth_id AS varchar(40)) IN ($sample)"
if ($r.err) { "  خطأ: $($r.err)" } else { $r.rows | Format-Table -AutoSize | Out-String | Write-Host }

Head "5) فاتورة اتقفلت (للمقارنة) - اقدم فاتورة توصيل"
$r = Q "SELECT TOP 3 h.sth_id, h.sth_deliv_closed, h.sth_dc_closed, h.sth_flag FROM sales_trans_h h WHERE h.sth_delivery=1 AND h.sth_id IN (SELECT sdc_bill_no FROM sales_deliv_close) ORDER BY h.sth_id DESC"
if ($r.err) { "  خطأ: $($r.err)" } else { $r.rows | Format-Table -AutoSize | Out-String | Write-Host }