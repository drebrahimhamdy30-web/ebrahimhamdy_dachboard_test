# ═══════════════════════════════════════════════════════════════════
#  sync_customer_credits.ps1 - pull "customer credit" lines from every
#  eplus branch database into Supabase.customer_credits.  READ-ONLY on
#  eplus; the only writes go to Supabase.
#
#  Run it on MASTER, where C:\phalix\sync_engine.json holds the four
#  branch connections and the service key:
#     powershell -NoProfile -ExecutionPolicy Bypass -File sync_customer_credits.ps1
#
#  What a "customer credit" is: the customer paid, the medicine was not
#  in stock, so a line with our item code 101 ("له ادويه بقيمة") is put
#  on the bill.  When he later collects it, eplus writes the returned
#  part back onto THAT SAME LINE (itm_back / itm_back_price) - there is
#  no separate return document.  So one table read gives both sides.
#
#  *** The item id is resolved per branch, never assumed. ***
#  Each branch runs its own Genius database, so the internal itm_id can
#  differ.  On mamora our code 101 is itm_id 51686, and itm_id 101 has
#  no rows at all - guessing would have silently returned nothing.  We
#  therefore probe with bills whose credit value we already know and
#  accept an id only if it matches on at least two independent bills.
#
#  ASCII-only source: PowerShell 5.1 reads a .ps1 without BOM as ANSI
#  and mangles Arabic, which breaks parsing with misleading errors.
# ═══════════════════════════════════════════════════════════════════
[CmdletBinding()]
param(
  [string]$ConfigPath = "C:\phalix\sync_engine.json",
  [string[]]$Only,                 # e.g. -Only mamora,bishr
  [int]$BatchSize = 500,
  [switch]$WhatIf                  # resolve + count only, write nothing
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# bills we already know carry code 101, with the line value, per branch.
# Taken from Supabase sales_items (itm_code='101').  Used only to find
# the internal item id - never written anywhere.
$PROBES = @{
  'mamora' = @(@('1502984', 55), @('1502934', 374), @('1502791', 213))
  'san'    = @(@('213964', 38), @('213296', 1600), @('211065', 357))
  'bishr'  = @(@('35519', 861), @('35392', 651), @('35281', 385))
  'seyouf' = @(@('2470', 3210), @('2395', 168), @('2395', 190))
}

if (-not (Test-Path $ConfigPath)) { throw "config not found: $ConfigPath" }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.supabaseUrl -or -not $cfg.serviceKey) { throw "config needs supabaseUrl + serviceKey" }
$SB = $cfg.supabaseUrl.TrimEnd('/')
$HDRS = @{
  apikey          = $cfg.serviceKey
  Authorization   = "Bearer $($cfg.serviceKey)"
  'Content-Type'  = 'application/json'
  Prefer          = 'resolution=merge-duplicates,return=minimal'
}

# Cairo wall-clock -> UTC, DST aware.  eplus stores naive local time;
# converting with the machine locale would be wrong on a UTC server, so
# the zone is named explicitly.
$CAIRO = [TimeZoneInfo]::FindSystemTimeZoneById('Egypt Standard Time')
function To-Utc([datetime]$naive) {
  $u = [DateTime]::SpecifyKind($naive, [DateTimeKind]::Unspecified)
  return [TimeZoneInfo]::ConvertTimeToUtc($u, $CAIRO).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
}

function New-Conn($b) {
  $cn = New-Object System.Data.SqlClient.SqlConnection(
    "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=30")
  $cn.Open(); return $cn
}
function Read-Rows($cn, $sql, $timeout = 900) {
  $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = $timeout
  $r = $c.ExecuteReader(); $out = New-Object System.Collections.ArrayList
  while ($r.Read()) {
    $o = @{}
    for ($i = 0; $i -lt $r.FieldCount; $i++) { $o[$r.GetName($i)] = if ($r.IsDBNull($i)) { $null } else { $r.GetValue($i) } }
    [void]$out.Add([pscustomobject]$o)
  }
  $r.Close(); return $out
}

# Resolve the credit item id from known bills.  Requires >= 2 hits so a
# single coincidental price match cannot pick the wrong item.
function Resolve-ItemId($cn, $branchKey) {
  $hits = @{}
  foreach ($setName in $PROBES.Keys) {
    foreach ($p in $PROBES[$setName]) {
      $bill = $p[0]; $val = [double]$p[1]
      try { $rows = Read-Rows $cn "SELECT itm_id, (qnty*itm_sell) line_val FROM sales_trans_d WHERE sth_id = $bill" 60 }
      catch { continue }
      foreach ($r in $rows) {
        if ($null -ne $r.line_val -and [math]::Abs([double]$r.line_val - $val) -lt 0.01) {
          $k = [string][int]$r.itm_id
          if (-not $hits.ContainsKey($k)) { $hits[$k] = 0 }
          $hits[$k]++
        }
      }
    }
  }
  if ($hits.Count -eq 0) { return $null }
  $best = $hits.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
  Write-Host ("    candidates: " + (($hits.GetEnumerator() | ForEach-Object { "$($_.Key)x$($_.Value)" }) -join ", ")) -ForegroundColor DarkGray
  if ($best.Value -lt 2) {
    Write-Host "    refusing: best id matched only once - not enough to be sure" -ForegroundColor Red
    return $null
  }
  return [int]$best.Key
}

function Push-Batch($rows) {
  if ($WhatIf -or $rows.Count -eq 0) { return }
  $body = $rows | ConvertTo-Json -Depth 4 -Compress
  if ($rows.Count -eq 1) { $body = "[$body]" }
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  Invoke-RestMethod -Method Post -Uri "$SB/rest/v1/customer_credits?on_conflict=branch,bill_no,line_no" `
                    -Headers $HDRS -Body $bytes | Out-Null
}

$branchKeys = $cfg.branches.PSObject.Properties.Name
if ($Only) { $branchKeys = $branchKeys | Where-Object { $Only -contains $_ } }
Write-Host ("branches in config: " + ($branchKeys -join ", ")) -ForegroundColor Cyan

$grandOpen = 0.0; $grandRows = 0
foreach ($bk in $branchKeys) {
  $b = $cfg.branches.$bk
  Write-Host "`n=== $bk ($($b.server)) ===" -ForegroundColor Yellow
  try { $cn = New-Conn $b } catch { Write-Host ("  connect failed: {0}" -f $_.Exception.Message) -ForegroundColor Red; continue }

  try {
    $itm = Resolve-ItemId $cn $bk
    if (-not $itm) { Write-Host "  credit item not resolved here - skipped" -ForegroundColor Red; $cn.Close(); continue }
    Write-Host ("  credit itm_id = {0}" -f $itm) -ForegroundColor Green

    # qnty*itm_sell is the sold value; itm_back*itm_back_price is what the
    # customer has already collected.  Customer name/mobile come straight
    # from Customer (readable text, unlike item names which are encrypted).
    $sql = @"
SELECT d.sth_id, d.std_id, h.sec_insert_date,
       s.sto_name_ar, c.cust_code, c.cust_name_ar, c.cust_mobile, e.e_Name,
       (d.qnty * d.itm_sell) AS val,
       (ISNULL(d.itm_back,0) * ISNULL(d.itm_back_price,0)) AS back
FROM sales_trans_d d
JOIN sales_trans_h h ON h.sth_id = d.sth_id
LEFT JOIN Store s    ON s.sto_id = h.sto_id
LEFT JOIN Customer c ON c.cust_id = h.cust_id
LEFT JOIN Employee e ON e.e_id = h.emp_id
WHERE d.itm_id = $itm
ORDER BY h.sec_insert_date
"@
    $rows = Read-Rows $cn $sql
    Write-Host ("  lines read: {0}" -f $rows.Count)

    $batch = New-Object System.Collections.ArrayList
    $sumVal = 0.0; $sumBack = 0.0; $n = 0
    foreach ($r in $rows) {
      $val = [double]$r.val; $back = [double]$r.back
      $sumVal += $val; $sumBack += $back
      [void]$batch.Add([ordered]@{
        branch         = $bk
        bill_no        = [string][int64]$r.sth_id
        line_no        = [int]$r.std_id
        bill_date      = (To-Utc ([datetime]$r.sec_insert_date))
        store_name     = $r.sto_name_ar
        cust_code      = if ($null -ne $r.cust_code) { ([string]$r.cust_code).Trim() } else { $null }
        cust_name      = $r.cust_name_ar
        cust_mobile    = if ($null -ne $r.cust_mobile) { ([string]$r.cust_mobile).Trim() } else { $null }
        employee_name  = $r.e_Name
        value          = [math]::Round($val, 2)
        returned_value = [math]::Round($back, 2)
      })
      if ($batch.Count -ge $BatchSize) { Push-Batch $batch; $n += $batch.Count; $batch.Clear() }
    }
    if ($batch.Count -gt 0) { Push-Batch $batch; $n += $batch.Count; $batch.Clear() }

    $open = [math]::Round($sumVal - $sumBack, 2)
    $grandOpen += $open; $grandRows += $rows.Count
    Write-Host ("  sold={0:N2}  collected={1:N2}  OUTSTANDING={2:N2}" -f $sumVal, $sumBack, $open) -ForegroundColor Cyan
    if ($WhatIf) { Write-Host "  (WhatIf - nothing written)" -ForegroundColor DarkGray }
    else { Write-Host ("  pushed {0} rows" -f $n) -ForegroundColor Green }
  }
  catch { Write-Host ("  FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red }
  finally { if ($cn.State -eq 'Open') { $cn.Close() } }
}

Write-Host ("`nTOTAL lines={0}  OUTSTANDING={1:N2}" -f $grandRows, $grandOpen) -ForegroundColor Yellow
Write-Host "done."
