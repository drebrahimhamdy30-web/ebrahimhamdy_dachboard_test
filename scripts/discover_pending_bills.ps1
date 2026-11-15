<#  discover_pending_bills.ps1 - هل نقدر نجيب الفواتير المعلقة من SQL مباشرة؟

    الليه: تطبيق eplus API بيتسلسل وبياخد لحد 90 ثانية للنداء الواحد، وبيختنق
    تحت حمل 4 فروع. في المقابل مهام المزامنة اللي بتقرا SQL مباشرة
    (cashier_txns / shifts / safes) شغالة كل دقيقة وسليمة حتى وقت ما الـAPI
    كان ميت (2026-11-15). فلو قدرنا نجيب رؤوس الطلبات من SQL مباشرة، نشيل
    الحمل التقيل عن الـAPI خالص.

    السكربت ده استكشاف فقط - قراءة بحتة بحساب phalix_reader.
    بياخد ارقام فواتير معروفة من رد الـAPI ويدور عليها في Genius عشان
    نعرف انهي جدول وانهي عمود فيه كل حقل، ويقيس زمن الاستعلام.

    الاستخدام:  .\scripts\discover_pending_bills.ps1
#>
param(
  [string[]]$SampleBills = @('1514068','1514067','1514062','1509513'),
  [string]$Server = "localhost"
)

$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 68); Write-Host "  $t"; Write-Host ("=" * 68) }

$pwFile = "C:\ProgramData\phalix\pw.txt"
if (-not (Test-Path $pwFile)) { Write-Host "مالقيتش ملف كلمة السر: $pwFile"; return }
$pw = (Get-Content $pwFile -Raw).Trim()
$cs = "Server=$Server;Database=Genius;User ID=phalix_reader;Password=$pw;Connect Timeout=15"
$pw = $null

function Run($sql, $label) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $c.Open()
    $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
    $rd = $cmd.ExecuteReader()
    $cols = @(); for ($i=0; $i -lt $rd.FieldCount; $i++) { $cols += $rd.GetName($i) }
    $rows = @()
    while ($rd.Read()) {
      $o = [ordered]@{}
      for ($i=0; $i -lt $rd.FieldCount; $i++) { $o[$cols[$i]] = $rd.GetValue($i) }
      $rows += [pscustomobject]$o
    }
    $rd.Close(); $sw.Stop()
    Write-Host ("  [{0}]  {1} صف في {2:N2} ثانية" -f $label, $rows.Count, $sw.Elapsed.TotalSeconds)
    return $rows
  } catch { $sw.Stop(); Write-Host ("  [{0}]  فشل بعد {1:N2}ث: {2}" -f $label, $sw.Elapsed.TotalSeconds, $_.Exception.Message); return @() }
  finally { $c.Close() }
}

Head "1) الجداول اللي فيها كلمة Transaction او Bill"
$t = Run "SELECT name FROM sysobjects WHERE xtype='U' AND (name LIKE '%Transaction%' OR name LIKE '%Bill%') ORDER BY name" "جداول"
$t | ForEach-Object { "    $($_.name)" }

Head "2) اعمدة F_Transaction_Header"
$c = Run "SELECT c.name, t.name AS typ, c.length FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('F_Transaction_Header') ORDER BY c.colid" "اعمدة"
$c | ForEach-Object { "    {0,-28} {1}({2})" -f $_.name, $_.typ, $_.length }

Head "3) ندور على فاتورة معروفة في F_Transaction_Header"
$list = ($SampleBills | ForEach-Object { "'" + $_ + "'" }) -join ","
$h = Run "SELECT TOP 4 * FROM F_Transaction_Header WHERE CAST(sth_id AS varchar(30)) IN ($list)" "بحث"
if ($h.Count -eq 0) {
  Write-Host "    مالقيتهاش بـsth_id - نجرب اعمدة تانية"
  $h = Run "SELECT TOP 4 * FROM F_Transaction_Header WHERE CAST(sth_no AS varchar(30)) IN ($list)" "بحث sth_no"
}
if ($h.Count -gt 0) {
  Write-Host ""
  Write-Host "  -- اول صف، الاعمدة غير الفاضية بس --"
  $r = $h[0]
  $r.PSObject.Properties | Where-Object { $_.Value -ne $null -and "$($_.Value)".Trim() -ne "" -and "$($_.Value)" -ne "0" } |
    ForEach-Object { "    {0,-28} = {1}" -f $_.Name, ("$($_.Value)" -replace "\s+"," ").Substring(0, [Math]::Min(55, "$($_.Value)".Length)) }
}

Head "4) زمن عد الفواتير المعلقة (المقارنة مع 90 ثانية بتاعة الـAPI)"
Run "SELECT COUNT(*) AS n FROM F_Transaction_Header WHERE sec_insert_date > DATEADD(day,-7,GETDATE())" "عد اسبوع" |
  ForEach-Object { "    فواتير آخر 7 ايام: $($_.n)" }

Head "الخلاصة"
Write-Host "  لو الاستعلامات فوق رجعت في أقل من ثانية، يبقى القراءة المباشرة"
Write-Host "  أسرع من الـAPI بمئات المرات، والخطة تنفّذ."
Write-Host "  الناقص بعدها: تحديد عمود حالة الفاتورة (Pending) وعلم التوصيل."