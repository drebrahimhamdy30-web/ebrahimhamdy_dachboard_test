<#  diag_eplus_api.ps1 - قياس مسار DeliveryBill الحقيقي محليًا مقابل الخارج
    يتشغل على MASTER (جهاز المعمورة). قراءة فقط - مجرد نداءات GET/POST.

    بيسأل عن بيانات اعتماد eplus (نفس credential اسمه "eplus" في n8n).
    الباسورد SecureString ومابيتكتبش في أي ملف ولا بيتطبع.

    الاستخدام:
      cd C:\phalix\dashboard ; git pull ; .\scripts\diag_eplus_api.ps1
#>
param(
  [string]$ApiPath = "/api/DeliveryBill/DeliveryBill",
  [string]$Host1   = "https://eplus.ebrahimhamdy.com",
  [int]$Rounds     = 5
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Head($t){ Write-Host ""; Write-Host ("=" * 64); Write-Host "  $t"; Write-Host ("=" * 64) }

Write-Host "بيانات اعتماد eplus API (من n8n - credential اسمه eplus)"
$u = Read-Host "  اسم المستخدم"
$sp = Read-Host "  كلمة السر" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp)
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$basic = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($u):$pw"))
$pw = $null

$payload = @{ bill_status_search = "Pending" }

function Probe($label, $uri, $withAuth) {
  $h = @{}
  if ($withAuth) { $h["Authorization"] = $basic }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -Uri $uri -Method POST -Body $payload -Headers $h -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $sw.Stop()
    $kb = [math]::Round($r.RawContentLength/1KB,1)
    Write-Host ("  {0,-26} HTTP {1}  {2,7:N2} ثانية  {3} كيلو" -f $label, $r.StatusCode, $sw.Elapsed.TotalSeconds, $kb)
    return $sw.Elapsed.TotalSeconds
  } catch {
    $sw.Stop()
    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "لا رد" }
    Write-Host ("  {0,-26} {1}  {2,7:N2} ثانية" -f $label, $code, $sw.Elapsed.TotalSeconds)
    return $sw.Elapsed.TotalSeconds
  }
}

Head "1) محليًا - بدون مصادقة (يقيس الوصول للتطبيق بس)"
Probe "localhost بلا auth" ("http://localhost" + $ApiPath) $false | Out-Null

Head "2) محليًا - بالمصادقة (الاستعلام الحقيقي) × $Rounds"
$local = @()
foreach ($i in 1..$Rounds) { $local += (Probe "localhost [$i]" ("http://localhost" + $ApiPath) $true) }

Head "3) من برّه عبر Cloudflare - نفس المسار × 3"
$ext = @()
foreach ($i in 1..3) { $ext += (Probe "cloudflare [$i]" ($Host1 + $ApiPath) $true) }

Head "الخلاصة"
$lm = [math]::Round(($local | Measure-Object -Average).Average,2)
$em = [math]::Round(($ext   | Measure-Object -Average).Average,2)
Write-Host "  متوسط محليًا:  $lm ثانية"
Write-Host "  متوسط خارجيًا: $em ثانية"
Write-Host ""
if ($lm -gt 10) {
  Write-Host "  => الاستعلام نفسه بطيء جوه التطبيق. العطل في IIS/SQL مش في النفق."
  Write-Host "     الخطوة الجاية: فهرسة/تحسين استعلام الفواتير المعلّقة للمعمورة."
} elseif ($em -gt ($lm * 3) -and $em -gt 5) {
  Write-Host "  => محلي سريع وخارجي بطيء. العطل في النفق أو الشبكة الخارجة."
} else {
  Write-Host "  => الاتنين متقاربين. لو مفيش فشل دلوقتي يبقى العطل متقطع - كرر وقت الذروة."
}

Head "استعلامات SQL المعلّقة (Genius)"
$q = "SET NOCOUNT ON; SELECT spid, status, blocked, waittype, DATEDIFF(second,last_batch,GETDATE()) AS secs, RTRIM(program_name) AS prog FROM master..sysprocesses WHERE dbid = DB_ID('Genius') AND spid > 50 ORDER BY secs DESC"
$tools = @()
foreach ($n in @("osql.exe","sqlcmd.exe")) {
  $c = Get-Command $n -ErrorAction SilentlyContinue
  if ($c) { $tools += $c.Source }
}
$tools += (Get-ChildItem "C:\Program Files\Microsoft SQL Server","C:\Program Files (x86)\Microsoft SQL Server" -Recurse -Include osql.exe,sqlcmd.exe -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$tools = $tools | Select-Object -Unique
if (-not $tools) { Write-Host "  مالقيتش osql ولا sqlcmd - افتح Query Analyzer يدوي" }
foreach ($t in $tools) {
  Write-Host "  -- $t"
  try { & $t -E -Q $q -w 400 2>&1 | Select-Object -First 25 | ForEach-Object { Write-Host "     $_" }; break }
  catch { Write-Host "     فشل: $($_.Exception.Message)" }
}