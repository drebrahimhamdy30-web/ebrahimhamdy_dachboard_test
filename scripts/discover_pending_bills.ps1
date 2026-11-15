<#  discover_pending_bills.ps1 - ايه الجدول اللي فيه فواتير المبيعات؟

    الليه: القراءة المباشرة اتأكدت إنها أسرع من الـAPI بمئات المرات
    (6276 فاتورة اتعدّت في 0.22 ثانية مقابل 90 ثانية للـAPI لستين فاتورة).
    الناقص بس إننا نحدد الجدول والأعمدة. F_Transaction_Header طلع جدول
    الحركات المالية مش فواتير المبيعات.

    السكربت بيدور اوتوماتيك: بيلاقي كل عمود اسمه فيه bill او sth او deliv،
    وبعدين بيدور على ارقام فواتير حقيقية جوه الاعمدة المرشحة لحد ما يلاقيها.

    قراءة بحتة بحساب phalix_reader.
#>
param(
  [string[]]$SampleBills = @('1514068','1514067','1514020','1513999'),
  [string]$Server = "localhost"
)

$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 70); Write-Host "  $t"; Write-Host ("=" * 70) }

$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Write-Host "مالقيتش $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null

function Q($sql, [int]$timeout = 30) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  try {
    $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = $timeout
    $rd = $cmd.ExecuteReader()
    $cols = @(); for ($i=0;$i -lt $rd.FieldCount;$i++){ $cols += $rd.GetName($i) }
    $rows = @()
    while ($rd.Read()) { $o=[ordered]@{}; for ($i=0;$i -lt $rd.FieldCount;$i++){ $o[$cols[$i]]=$rd.GetValue($i) }; $rows += [pscustomobject]$o }
    $rd.Close(); return ,$rows
  } catch { return ,@() } finally { $c.Close() }
}

Head "1) الاعمدة اللي اسمها فيه bill / sth / deliv"
$cands = Q "SELECT o.name AS tbl, c.name AS col FROM syscolumns c JOIN sysobjects o ON o.id=c.id WHERE o.xtype='U' AND (c.name LIKE '%bill%' OR c.name LIKE 'sth%' OR c.name LIKE '%deliv%') ORDER BY o.name, c.name"
$cands | Group-Object tbl | ForEach-Object {
  "    {0,-34} : {1}" -f $_.Name, (($_.Group | ForEach-Object { $_.col }) -join ", ")
}

Head "2) ندور على ارقام الفواتير الحقيقية في الاعمدة المرشحة"
$numCols = $cands | Where-Object { $_.col -match 'bill_no|bill_id|^sth_id$|^sth_no$|bill_num' }
$list = ($SampleBills | ForEach-Object { "'" + $_ + "'" }) -join ","
$found = @()
foreach ($x in $numCols) {
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $r = Q "SELECT COUNT(*) AS n FROM [$($x.tbl)] WHERE CAST([$($x.col)] AS varchar(40)) IN ($list)" 20
  $sw.Stop()
  $n = if ($r.Count) { $r[0].n } else { 0 }
  if ($n -gt 0) {
    "    ✅ {0}.{1}  لقى {2} من {3}   ({4:N2}ث)" -f $x.tbl, $x.col, $n, $SampleBills.Count, $sw.Elapsed.TotalSeconds
    $found += $x
  }
}
if (-not $found) { Write-Host "    مالقيناش الارقام دي في اي عمود مرشح" }

Head "3) الصف الكامل من افضل جدول"
if ($found) {
  $best = $found[0]
  $row = Q "SELECT TOP 1 * FROM [$($best.tbl)] WHERE CAST([$($best.col)] AS varchar(40)) IN ($list)" 20
  if ($row.Count) {
    "    الجدول: $($best.tbl)   العمود: $($best.col)"
    Write-Host ""
    $row[0].PSObject.Properties | Where-Object { $_.Value -ne $null -and "$($_.Value)".Trim() -ne "" } |
      ForEach-Object {
        $v = ("$($_.Value)" -replace "\s+"," ")
        if ($v.Length -gt 60) { $v = $v.Substring(0,60) + "..." }
        "      {0,-30} = {1}" -f $_.Name, $v
      }
  }
}

Head "4) جداول اسمها فيه sale او deliv او order"
$t2 = Q "SELECT name FROM sysobjects WHERE xtype='U' AND (name LIKE '%sale%' OR name LIKE '%deliv%' OR name LIKE '%order%') ORDER BY name"
$t2 | ForEach-Object { "    $($_.name)" }