# diag_expiry.ps1 — فحص تواريخ الصلاحية في eplus لكل فرع من سيرفره هو. قراءة فقط.
#
# بيجاوب على تلات أسئلة:
#   ١) كل سيرفر شايف بيانات أنهي فروع؟ (ولا كل فرع شايف نفسه بس)
#   ٢) تغطية الصلاحية: كام صنف له رصيد وكام منهم له تاريخ صلاحية
#   ٣) الربط: كودنا في سوبابيز بيلاقي نفسه في eplus ولا لأ — وبأي معامل وحدة
#
# ⚠️ مابيكتبش أي حاجة. لا في eplus ولا في سوبابيز. READ UNCOMMITTED زي محرّك المزامنة.
#
#   .\diag_expiry.ps1
#   .\diag_expiry.ps1 -Out C:\temp\expiry.txt

param(
  [string]$ConfigPath = "C:\ProgramData\phalix\sync_engine.json",
  [string]$Out = "$env:TEMP\diag_expiry.txt"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$lines = New-Object System.Collections.Generic.List[string]
function Say($m){ Write-Host $m; $lines.Add($m) }

try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
catch { Write-Host "تعذّر قراءة الإعدادات: $ConfigPath"; exit 1 }

$SB  = $cfg.supabaseUrl.TrimEnd('/')
$Hdr = @{ apikey = $cfg.serviceKey; Authorization = "Bearer $($cfg.serviceKey)" }

# الفرع -> (رقمه في eplus، عمود رصيده في stock_flat)
$MAP = @{
  mamora = @{ sto = 1;  col = 'm_q'; ar = 'المعمورة' }
  san    = @{ sto = 26; col = 's_q'; ar = 'سان ستيفانو' }
  bishr  = @{ sto = 28; col = 'b_q'; ar = 'سيدى بشر' }
  seyouf = @{ sto = 29; col = 'f_q'; ar = 'السيوف' }
}

function Open-Eplus($b){
  $cn = New-Object System.Data.SqlClient.SqlConnection(
    "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
  $cn.Open()
  $c = $cn.CreateCommand(); $c.CommandText = "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"
  $c.ExecuteNonQuery() | Out-Null
  return $cn
}

# كل أرصدة الفرع من سوبابيز (مرقّم — السقف 1000)
function Get-OurStock($col){
  $all = @{}; $off = 0
  while ($true) {
    $u = "$SB/rest/v1/stock_flat?select=itm_code,$col&$col=gt.0&order=itm_code.asc&limit=1000&offset=$off"
    $page = Invoke-RestMethod -Uri $u -Headers $Hdr -Method Get
    if (-not $page -or $page.Count -eq 0) { break }
    foreach ($r in $page) { $all[[string]$r.itm_code] = [double]$r.$col }
    if ($page.Count -lt 1000) { break }
    $off += 1000
  }
  return $all
}

Say ""
Say "=========================================================="
Say " فحص الصلاحية في eplus — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Say "=========================================================="

foreach ($name in @('mamora','san','bishr','seyouf')) {
  $b = $cfg.branches.$name
  $m = $MAP[$name]
  Say ""
  Say "### $($m.ar)  [$name]"

  if (-not $b) { Say "   مش في الإعدادات — اتخطّى"; continue }
  Say "   سيرفر: $($b.server)"

  try { $cn = Open-Eplus $b }
  catch { Say "   [فشل] الاتصال: $($_.Exception.Message.Split([char]10)[0].Trim())"; continue }

  try {
    # ١) السيرفر ده شايف أنهي فروع؟
    $c = $cn.CreateCommand(); $c.CommandTimeout = 300
    $c.CommandText = "SELECT sto_id, COUNT(DISTINCT itm_id) n FROM Item_Class_Store WHERE itm_qty > 0 GROUP BY sto_id ORDER BY 2 DESC"
    $r = $c.ExecuteReader(); $seen = @()
    while ($r.Read()) { $seen += ("{0}:{1}" -f $r.GetValue(0), $r.GetValue(1)) }
    $r.Close()
    Say "   الفروع الظاهرة هنا (رقم:أصناف) -> $($seen -join '  ')"

    # ٢) تغطية الصلاحية لفرعه هو
    $c2 = $cn.CreateCommand(); $c2.CommandTimeout = 300
    $c2.CommandText = "SELECT COUNT(DISTINCT itm_id) items, SUM(CASE WHEN itm_expiry_date IS NULL THEN 1 ELSE 0 END) no_exp, SUM(CASE WHEN itm_expiry_date IS NOT NULL AND itm_expiry_date < DATEADD(month,6,GETDATE()) THEN 1 ELSE 0 END) soon, COUNT(*) rows_ FROM Item_Class_Store WHERE itm_qty > 0 AND sto_id = $($m.sto)"
    $r2 = $c2.ExecuteReader()
    if ($r2.Read()) {
      Say ("   رصيد: {0} صنف في {1} سطر · بلا صلاحية {2} · تنتهي خلال 6 شهور {3}" -f $r2.GetValue(0), $r2.GetValue(3), $r2.GetValue(1), $r2.GetValue(2))
    }
    $r2.Close()

    # ٣) اختبار الربط والوحدات مقابل أرصدتنا
    $ours = Get-OurStock $m.col
    $c3 = $cn.CreateCommand(); $c3.CommandTimeout = 300
    $c3.CommandText = "SELECT itm_id, SUM(itm_qty) q FROM Item_Class_Store WHERE itm_qty > 0 AND sto_id = $($m.sto) GROUP BY itm_id"
    $r3 = $c3.ExecuteReader(); $theirs = @{}
    while ($r3.Read()) { $theirs[[string][int]$r3.GetValue(0)] = [double]$r3.GetValue(1) }
    $r3.Close()

    $hit = 0; $miss = 0; $ratios = @{}; $missSample = @()
    foreach ($code in $ours.Keys) {
      if ($theirs.ContainsKey($code)) {
        $hit++
        $o = $ours[$code]
        if ($o -gt 0) {
          $k = [math]::Round($theirs[$code] / $o, 2)
          if ($ratios.ContainsKey($k)) { $ratios[$k]++ } else { $ratios[$k] = 1 }
        }
      } else {
        $miss++
        if ($missSample.Count -lt 10) { $missSample += $code }
      }
    }
    $tot = $hit + $miss
    $pct = if ($tot) { [math]::Round(100.0 * $hit / $tot, 1) } else { 0 }
    Say ("   الربط: {0} من {1} لاقوا نفسهم في eplus ({2}%) · ضايعين {3}" -f $hit, $tot, $pct, $miss)
    if ($missSample.Count) { Say ("   عيّنة ضايعة: {0}" -f ($missSample -join ', ')) }

    $top = $ratios.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6
    $txt = ($top | ForEach-Object { "x{0}={1}" -f $_.Key, $_.Value }) -join '  '
    Say "   معامل الوحدة (كمية eplus / كميتنا): $txt"
  }
  catch { Say "   [خطأ] $($_.Exception.Message.Split([char]10)[0].Trim())" }
  finally { $cn.Close() }
}

Say ""
Say "=========================================================="
$lines | Set-Content -Path $Out -Encoding UTF8
Write-Host "اتحفظ في: $Out"
