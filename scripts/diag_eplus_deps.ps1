<#  diag_eplus_deps.ps1 - قياس اعتماديات eplus API وفحص مزامنة Google Drive

    الليه: اتكشف يوم 2026-11-15 ان API المعمورة مش بيقرا من Genius المحلية بس -
    هو فاتح 10 اتصالات لـSQL على 26.77.14.149 (عبر Radmin VPN) و10 اتصالات
    لـ196.13.244.235:441. دي اعتماديات مخفية كانت غايبة عن كل توثيقنا.

    وقياس اولي بـTest-NetConnection ادى 9 ثواني لكل واحد - لكن الاداة دي بتعمل
    ping و DNS قبل الـTCP، فالرقم ده مش موثوق. السكربت ده بيقيس زمن اتصال TCP
    الصافي بس، عدة مرات، عشان نعرف لو فيه بطء حقيقي ولا كان وهم من اداة القياس.

    وكمان بيفحص هل مجلد التطبيق داخل مزامنة Google Drive - لان قفل web.config
    هو اللي وقف التطبيق، وGoogleDriveFS كان بيشتغل بعد اعادة التشغيل بدقيقة.

    قراءة فقط - مابيغيرش اي حاجة.
#>
param([int]$Samples = 8)

$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 66); Write-Host "  $t"; Write-Host ("=" * 66) }

function Measure-Tcp([string]$ip, [int]$port, [int]$n) {
  $ok = @(); $fail = 0
  for ($i = 0; $i -lt $n; $i++) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $iar = $c.BeginConnect($ip, $port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(10000, $false)) {
        $c.EndConnect($iar); $sw.Stop(); $ok += $sw.Elapsed.TotalMilliseconds
      } else { $fail++ }
    } catch { $fail++ } finally { $c.Close() }
    Start-Sleep -Milliseconds 300
  }
  if ($ok.Count -gt 0) {
    $st = $ok | Measure-Object -Average -Minimum -Maximum
    "{0,-18}:{1,-6} نجاح {2}/{3}   متوسط {4:N0} م.ث   اقل {5:N0}   اكبر {6:N0}" -f $ip, $port, $ok.Count, $n, $st.Average, $st.Minimum, $st.Maximum
    if ($st.Average -gt 1000) { "    تحذير: بطء حقيقي في الاتصال - اكتر من ثانية لفتح TCP" }
  } else {
    "{0,-18}:{1,-6} فشل كل المحاولات ({2})" -f $ip, $port, $n
  }
}

Head "1) زمن اتصال TCP الصافي (بدون ping ولا DNS)"
Write-Host "  للمقارنة بنقيس كمان SQL المحلي وسيرفر معروف سريع"
Measure-Tcp "26.77.14.149"   1433 $Samples
Measure-Tcp "196.13.244.235" 441  $Samples
Measure-Tcp "127.0.0.1"      1433 $Samples
Measure-Tcp "1.1.1.1"        443  $Samples

Head "2) اتصالات العامل الحالي"
$w = Get-CimInstance Win32_Process -Filter "name='w3wp.exe'" | Where-Object { $_.CommandLine -match 'EPlusIntegrationAPI' }
if ($w) {
  "  PID $($w.ProcessId)  بدأ $($w.CreationDate)"
  Get-NetTCPConnection -OwningProcess $w.ProcessId -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne "Bound" } |
    Group-Object { "{0,-12} {1}:{2}" -f $_.State, $_.RemoteAddress, $_.RemotePort } |
    ForEach-Object { "    {0,4} x  {1}" -f $_.Count, $_.Name }
} else { "  مفيش عامل شغال للـAPI" }

Head "3) هل مجلد التطبيق داخل مزامنة Google Drive؟"
$appDir = "D:\EPlus API"
$gd = Get-Process GoogleDriveFS -ErrorAction SilentlyContinue
if (-not $gd) { "  GoogleDriveFS مش شغال حاليا" } else { "  GoogleDriveFS شغال - $($gd.Count) عملية" }

$found = $false
$dbs = Get-ChildItem "$env:LOCALAPPDATA\Google\DriveFS" -Recurse -Filter "mirror_metadata_sqlite.db" -ErrorAction SilentlyContinue
foreach ($db in $dbs) {
  try {
    $fs = [IO.File]::Open($db.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $buf = New-Object byte[] $fs.Length
    $null = $fs.Read($buf, 0, $fs.Length)
    $fs.Close()
    $txt = [Text.Encoding]::UTF8.GetString($buf)
    if ($txt -match "EPlus API") {
      "  تحذير: 'EPlus API' موجود في قاعدة مزامنة Google Drive"
      "         $($db.FullName)"
      $found = $true
    }
  } catch { "  تعذر فحص $($db.Name): $($_.Exception.Message)" }
}
if (-not $found -and $dbs) { "  'EPlus API' مش موجود في قواعد المزامنة - المجلد غالبا برا Google Drive" }

Head "4) مين بيكتب في web.config"
$cfg = Join-Path $appDir "ePlusIntegrationAPI\web.config"
if (Test-Path $cfg) {
  $i = Get-Item $cfg
  "  اخر تعديل : $($i.LastWriteTime)"
  "  الحجم     : $($i.Length) بايت"
  try { $fs=[IO.File]::Open($cfg,'Open','Read','None'); "  القفل     : حر"; $fs.Close() }
  catch { "  القفل     : مقفول الان => $($_.Exception.Message)" }
} else { "  مالقيتش $cfg" }

Head "الخلاصة"
Write-Host "  قارن متوسط 26.77.14.149 و 196.13.244.235 بمتوسط 1.1.1.1"
Write-Host "  لو متقاربين فالـ9 ثواني القديمة كانت من اداة القياس مش بطء حقيقي."
Write-Host "  لو اكبر بكتير فدي اعتمادية بطيئة بجد وتستاهل متابعة."