<#  map_sales_trans_h.ps1 - خريطة أعمدة فاتورة المبيعات مقابل رد الـAPI

    الليه: الكشف السابق حدد ان sales_trans_h هو جدول رؤوس الفواتير
    (sth_id = bill_no، لقى 4 من 4 في 0.28 ثانية) وان sales_deliv_info
    فيه الطيار. الناقص: نثبت ان sth_delivery + sth_deliv_closed بيساووا
    فلتر Pending بتاع الـAPI، ونعرف كل حقل في انهي عمود.

    بيقارن عدد الصفوف بالفلتر المقترح مع 60 (العدد اللي الـAPI رجعه).
    قراءة بحتة بحساب phalix_reader.
#>
param(
  [string]$Bill = "1514068",
  [string]$Server = "localhost"
)
$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 70); Write-Host "  $t"; Write-Host ("=" * 70) }

$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Write-Host "مالقيتش $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null

function Q($sql, [int]$t = 40) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = $t
    $rd = $cmd.ExecuteReader()
    $cols=@(); for($i=0;$i -lt $rd.FieldCount;$i++){ $cols += $rd.GetName($i) }
    $rows=@()
    while ($rd.Read()) { $o=[ordered]@{}; for($i=0;$i -lt $rd.FieldCount;$i++){ $o[$cols[$i]]=$rd.GetValue($i) }; $rows += [pscustomobject]$o }
    $rd.Close(); $sw.Stop()
    return [pscustomobject]@{ rows=$rows; sec=$sw.Elapsed.TotalSeconds; err=$null }
  } catch { $sw.Stop(); return [pscustomobject]@{ rows=@(); sec=$sw.Elapsed.TotalSeconds; err=$_.Exception.Message } }
  finally { $c.Close() }
}

Head "1) كل اعمدة sales_trans_h"
$r = Q "SELECT c.name, t.name AS typ FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('sales_trans_h') ORDER BY c.colid"
"  العدد: $($r.rows.Count)"
$r.rows | ForEach-Object { "    {0,-26} {1}" -f $_.name, $_.typ }

Head "2) الصف الكامل للفاتورة $Bill"
$r = Q "SELECT TOP 1 * FROM sales_trans_h WHERE CAST(sth_id AS varchar(40)) = '$Bill'"
if ($r.err) { "  خطأ: $($r.err)" }
elseif ($r.rows.Count -eq 0) { "  مالقيتهاش" }
else {
  "  ({0:N2} ثانية)" -f $r.sec
  $r.rows[0].PSObject.Properties | Where-Object { $_.Value -ne $null -and "$($_.Value)".Trim() -ne "" } | ForEach-Object {
    $v = ("$($_.Value)" -replace "\s+"," "); if ($v.Length -gt 55) { $v = $v.Substring(0,55)+"..." }
    "    {0,-26} = {1}" -f $_.Name, $v
  }
}

Head "3) معلومات التوصيل لنفس الفاتورة"
$r = Q "SELECT TOP 1 * FROM sales_deliv_info WHERE CAST(sth_id AS varchar(40)) = '$Bill'"
if ($r.rows.Count) {
  $r.rows[0].PSObject.Properties | ForEach-Object { "    {0,-26} = {1}" -f $_.Name, $_.Value }
} else { "  مفيش صف" }

Head "4) اختبار فلتر Pending — المفروض يقارب 60"
$tests = @(
  @("sth_delivery=1 AND sth_deliv_closed=0",                      "توصيل غير مقفول"),
  @("sth_delivery=1 AND ISNULL(sth_deliv_closed,0)=0",            "نفسه مع NULL"),
  @("sth_delivery=1 AND ISNULL(sth_deliv_closed,0)=0 AND sth_flag=0", "+ sth_flag=0"),
  @("sth_delivery=1",                                             "كل التوصيل")
)
foreach ($t in $tests) {
  $r = Q "SELECT COUNT(*) AS n FROM sales_trans_h WHERE $($t[0])"
  if ($r.err) { "    {0,-34} خطأ: {1}" -f $t[1], $r.err }
  else { "    {0,-34} = {1,6}   ({2:N2}ث)" -f $t[1], $r.rows[0].n, $r.sec }
}

Head "5) اخر 5 فواتير توصيل غير مقفولة"
$r = Q "SELECT TOP 5 sth_id, bill_typ, delivery_date, total_bill_net, sth_deliv_closed, sth_contract, sth_cash FROM sales_trans_h WHERE sth_delivery=1 AND ISNULL(sth_deliv_closed,0)=0 ORDER BY sth_id DESC"
if ($r.err) { "  خطأ: $($r.err)" }
else {
  "  ({0:N2} ثانية)" -f $r.sec
  $r.rows | Format-Table -AutoSize | Out-String | Write-Host
}