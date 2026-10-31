# setup_region_tasks.ps1  — تجهيز مهام مناطق العملاء على الماستر (مرة واحدة).
# يشتغل كـ(Run as Administrator). بيعمل:
#   1) فولدر C:\phalix وتنزيل region_writeback.ps1 فيه.
#   2) تخزين مفتاح service_role فى متغيّر بيئة للجهاز.
#   3) تشفير باسوورد phalix_writer بمفتاح AES (ملف) — عشان المهمة تفكّه كـSYSTEM.
#   4) تقييد صلاحيات الفولدر (SYSTEM + Administrators فقط).
#   5) مهمتين مجدولتين:
#        Phalix_Region_Apply  — كل دقيقة، تطبيق فقط (خفيف: يقرا الطابور، لو فاضى يقفل).
#        Phalix_Region_Sync   — كل 10 دقايق، مزامنة المناطق + العناوين (الأثقل).
#
# الأسرار (المفتاح/الباسوورد المشفّر/متغيّر البيئة) على الجهاز فقط، مش فى الريبو.

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function L($m){ Write-Host $m }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L "وقّف: افتح PowerShell كـ(Run as Administrator)."; exit 1 }

$dir = "C:\phalix"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# 1) تنزيل المحرّك (بكسر الكاش)
$u = "https://raw.githubusercontent.com/drebrahimhamdy30-web/ebrahimhamdy_dachboard/main/scripts/region_writeback.ps1?x=" + (Get-Random)
Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile "$dir\region_writeback.ps1"
L "✓ اتنزّل region_writeback.ps1"

# 2) مفتاح service_role → متغيّر بيئة للجهاز
$svc = Read-Host "الصق مفتاح service_role (من Supabase → Settings → API)"
if ([string]::IsNullOrWhiteSpace($svc)) { L "وقّف: المفتاح فاضى."; exit 1 }
[Environment]::SetEnvironmentVariable("SUPABASE_SERVICE_KEY", $svc.Trim(), "Machine")
L "✓ اتخزّن مفتاح الخدمة لمتغيّر بيئة الجهاز"

# 3) تشفير باسوورد phalix_writer بمفتاح AES
$key = New-Object byte[] 32
([System.Security.Cryptography.RNGCryptoServiceProvider]::new()).GetBytes($key)
[IO.File]::WriteAllBytes("$dir\rw.key", $key)
$pwSec = Read-Host "باسوورد phalix_writer" -AsSecureString
if ($pwSec.Length -eq 0) { L "وقّف: الباسوورد فاضى."; exit 1 }
($pwSec | ConvertFrom-SecureString -Key $key) | Set-Content "$dir\rw.sec" -Encoding ASCII
L "✓ اتشفّر الباسوورد"

# 4) تقييد صلاحيات الفولدر (SYSTEM + Administrators فقط) — SIDs عشان أى لغة ويندوز
& icacls $dir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
L "✓ اتقيّدت صلاحيات $dir"

# 5) المهام المجدولة (كـSYSTEM — SYSTEM بيفكّ الـAES من الملف)
$common = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dir\region_writeback.ps1 -PasswordFile $dir\rw.sec -KeyFile $dir\rw.key"
& schtasks /create /tn "Phalix_Region_Apply" /tr "$common -ApplyOnly" /sc minute /mo 1  /ru SYSTEM /rl HIGHEST /f | Out-Null
& schtasks /create /tn "Phalix_Region_Sync"  /tr "$common -SyncOnly"  /sc minute /mo 10 /ru SYSTEM /rl HIGHEST /f | Out-Null
L "✓ اتعملت المهمتان: Phalix_Region_Apply (كل دقيقة) + Phalix_Region_Sync (كل 10 د)"

# تشغيل فورى للمزامنة عشان الشاشة تتعبّى حالاً
& schtasks /run /tn "Phalix_Region_Sync" | Out-Null
L ""
L "تمام. المهام شغّالة. للمتابعة:"
L "   schtasks /query /tn Phalix_Region_Apply /v /fo LIST"
L "   (أو افتح Task Scheduler)"
