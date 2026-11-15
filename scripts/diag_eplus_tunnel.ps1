<#  diag_eplus_tunnel.ps1 - فحص الطريق بين Cloudflare وجهاز المعمورة
    يتشغل على MASTER. قراءة فقط.
    -Path  مسار الـAPI الحقيقي اللي n8n بينادي عليه، مثال:
           .\scripts\diag_eplus_tunnel.ps1 -Path "/api/delivery/pending?branch=1"
#>
param([string]$Path = "/")

$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 62); Write-Host "  $t"; Write-Host ("=" * 62) }

Head "1) حمل الجهاز (بدون عدادات الأداء - الأسماء معرّبة عندك)"
try {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
  $freeMB = [math]::Round($os.FreePhysicalMemory/1KB,0)
  $totMB  = [math]::Round($os.TotalVisibleMemorySize/1KB,0)
  Write-Host "  المعالج: $cpu %   الذاكرة الحرة: $freeMB من $totMB ميجا"
} catch { Write-Host "  تعذّر: $($_.Exception.Message)" }

Head "2) نفق Cloudflare - موجود ومشغّل؟"
$svc = Get-Service | Where-Object { $_.Name -match "cloudflare|tunnel|ngrok" }
if ($svc) { $svc | ForEach-Object { Write-Host ("  خدمة {0,-26} {1}" -f $_.Name, $_.Status) } }
else { Write-Host "  مفيش خدمة باسم cloudflare/tunnel" }

$proc = Get-Process | Where-Object { $_.ProcessName -match "cloudflared|ngrok|frpc" }
if ($proc) {
  foreach ($p in $proc) {
    $up = [math]::Round(((Get-Date) - $p.StartTime).TotalMinutes,0)
    Write-Host ("  عملية {0,-18} PID {1,-7} شغالة من {2} دقيقة" -f $p.ProcessName, $p.Id, $up)
  }
} else { Write-Host "  مفيش عملية cloudflared شغالة" }

Head "3) مين سامع على البورتات (80/443 ومنافذ النفق)"
try {
  Get-NetTCPConnection -State Listen -ErrorAction Stop |
    Where-Object { $_.LocalPort -in 80,443,8080,8443,3000,5000 } |
    Select-Object LocalAddress, LocalPort, @{n="عملية";e={ (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }} |
    Sort-Object LocalPort -Unique | Format-Table -AutoSize | Out-String | Write-Host
} catch { Write-Host "  تعذّر: $($_.Exception.Message)" }

Head "4) سرعة الرد محليًا على المسار الحقيقي"
Write-Host "  المسار المفحوص: $Path"
foreach ($i in 1..5) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -Uri ("http://localhost" + $Path) -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $sw.Stop()
    Write-Host ("  [{0}] HTTP {1}  في {2:N2} ثانية  ({3} بايت)" -f $i, $r.StatusCode, $sw.Elapsed.TotalSeconds, $r.RawContentLength)
  } catch {
    $sw.Stop()
    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "لا رد" }
    Write-Host ("  [{0}] {1}  في {2:N2} ثانية" -f $i, $code, $sw.Elapsed.TotalSeconds)
  }
}

Head "5) نفس المسار من برّه عبر Cloudflare (من الجهاز نفسه)"
foreach ($i in 1..3) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -Uri ("https://eplus.ebrahimhamdy.com" + $Path) -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $sw.Stop()
    Write-Host ("  [{0}] HTTP {1}  في {2:N2} ثانية" -f $i, $r.StatusCode, $sw.Elapsed.TotalSeconds)
  } catch {
    $sw.Stop()
    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "لا رد" }
    Write-Host ("  [{0}] {1}  في {2:N2} ثانية" -f $i, $code, $sw.Elapsed.TotalSeconds)
  }
}
Write-Host ""
Write-Host "  محلي سريع + خارجي بطيء  =>  العطل في النفق أو الشبكة الخارجة"
Write-Host "  الاتنين بطيئين            =>  العطل في IIS أو SQL"

Head "6) استعلامات SQL المعلّقة (Genius)"
$q = "SET NOCOUNT ON; SELECT spid, status, blocked, waittype, DATEDIFF(second,last_batch,GETDATE()) AS secs, RTRIM(program_name) AS prog FROM master..sysprocesses WHERE dbid = DB_ID('Genius') AND spid > 50 ORDER BY secs DESC"
$tools = @()
foreach ($n in @("osql.exe","sqlcmd.exe")) {
  $c = Get-Command $n -ErrorAction SilentlyContinue
  if ($c) { $tools += $c.Source }
}
$tools += (Get-ChildItem "C:\Program Files\Microsoft SQL Server","C:\Program Files (x86)\Microsoft SQL Server" -Recurse -Include osql.exe,sqlcmd.exe -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$tools = $tools | Select-Object -Unique
if (-not $tools) { Write-Host "  مالقيتش osql ولا sqlcmd على الجهاز" }
foreach ($t in $tools) {
  Write-Host "  -- $t"
  try {
    & $t -E -Q $q -w 400 2>&1 | Select-Object -First 25 | ForEach-Object { Write-Host "     $_" }
    break
  } catch { Write-Host "     فشل: $($_.Exception.Message)" }
}