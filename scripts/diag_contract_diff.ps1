# diag_contract_diff.ps1 - compare contract bill numbers, eplus vs Supabase,
# one by one for a given month.  READ-ONLY on both sides.
#
# A count comparison cannot tell these two apart, and they mean opposite things:
#   - in eplus, not with us  -> a real sync gap (invoices we never received)
#   - with us, not in eplus  -> rows we hold that eplus has no contract bill
#                               for (added by hand, wrong branch, other id)
#
# ASCII-only on purpose: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and
# mangles Arabic, which breaks parsing with misleading errors.  The Arabic
# branch name is looked up from the branches table instead of being typed here.
#   .\diag_contract_diff.ps1 -Branch all -Ym 2026-10
param(
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json",
  [string]$Branch = "mamora",      # or "all" for every branch in the config
  [string]$Ym = "2026-10"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$SB  = $cfg.supabaseUrl.TrimEnd('/')
$H   = @{ apikey = $cfg.serviceKey; Authorization = "Bearer $($cfg.serviceKey)" }

function Get-Json($url) {
  $resp = Invoke-WebRequest -Uri $url -Headers $H -UseBasicParsing
  return ($resp.Content | ConvertFrom-Json)
}

# -Branch all: re-run this same script once per branch, then stop
if ($Branch -eq 'all') {
  foreach ($bk in $cfg.branches.PSObject.Properties.Name) {
    Write-Host ("`n================ {0} ================" -f $bk) -ForegroundColor Magenta
    & $PSCommandPath -ConfigPath $ConfigPath -Branch $bk -Ym $Ym
  }
  return
}

# branch name in Arabic, straight from the table - never typed in this file
$brRow = Get-Json "$SB/rest/v1/branches?select=name&code=eq.$Branch&limit=1"
if (-not $brRow -or $brRow.Count -eq 0) { throw "branch '$Branch' not found in branches" }
$brAr = $brRow[0].name
Write-Host ("branch: {0}  month: {1}" -f $Branch, $Ym) -ForegroundColor Cyan

# ---------- eplus ----------
$b = $cfg.branches.$Branch
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=25")
$cn.Open()
$c = $cn.CreateCommand(); $c.CommandTimeout = 900
$c.CommandText = "SELECT sth_id, total_bill, sth_flag FROM sales_trans_h " +
                 "WHERE sth_contract = 1 AND CONVERT(char(7), sec_insert_date, 126) = '$Ym'"
$r = $c.ExecuteReader()
$ep = @{}
while ($r.Read()) { $ep[[string][int64]$r['sth_id']] = [double]$r['total_bill'] }
$r.Close(); $cn.Close()
$epSum = ($ep.Values | Measure-Object -Sum).Sum
Write-Host ("eplus    : {0,5} contract bills   gross {1,12:N2}" -f $ep.Count, $epSum)

# ---------- Supabase (paged: REST caps at 1000) ----------
# NOTE: the row table is $sbRows, NOT $sb.  PowerShell variable names are
# case-insensitive, so $sb silently overwrites $SB (the server URL) and every
# later request goes to host "system.collections.hashtable".
$enc  = [uri]::EscapeDataString($brAr)
$next = ([datetime]"$Ym-01").AddMonths(1).ToString('yyyy-MM')
$sbRows = @{}
$off = 0
while ($true) {
  $u = "$SB/rest/v1/contract_invoices?select=bill_no,total_bill"
  $u = $u + "&branch=eq." + $enc
  $u = $u + "&bill_date=gte." + $Ym + "-01T00:00:00%2B02:00"
  $u = $u + "&bill_date=lt." + $next + "-01T00:00:00%2B02:00"
  $u = $u + "&order=bill_no&limit=1000&offset=" + $off
  $page = Get-Json $u
  if (-not $page -or $page.Count -eq 0) { break }
  foreach ($x in $page) { $sbRows[[string]$x.bill_no] = [double]$x.total_bill }
  $off += $page.Count
  if ($page.Count -lt 1000) { break }
}
$sbSum = ($sbRows.Values | Measure-Object -Sum).Sum
Write-Host ("supabase : {0,5} rows             gross {1,12:N2}" -f $sbRows.Count, $sbSum)

# ---------- the two gaps ----------
$missing = @($ep.Keys | Where-Object { -not $sbRows.ContainsKey($_) })
$extra   = @($sbRows.Keys | Where-Object { -not $ep.ContainsKey($_) })
$mSum = if ($missing.Count) { (($missing | ForEach-Object { $ep[$_] }) | Measure-Object -Sum).Sum } else { 0 }
$xSum = if ($extra.Count)   { (($extra   | ForEach-Object { $sbRows[$_] }) | Measure-Object -Sum).Sum } else { 0 }

Write-Host ("`n>>> in eplus, NOT with us : {0} bill(s), gross {1:N2}" -f $missing.Count, $mSum) -ForegroundColor Red
$missing | Sort-Object | Select-Object -First 25 | ForEach-Object { Write-Host ("    {0}   {1,10:N2}" -f $_, $ep[$_]) }

Write-Host ("`n>>> with us, NOT a contract bill in eplus : {0} row(s), gross {1:N2}" -f $extra.Count, $xSum) -ForegroundColor Yellow
$extra | Sort-Object | Select-Object -First 25 | ForEach-Object { Write-Host ("    {0}   {1,10:N2}" -f $_, $sbRows[$_]) }

Write-Host "`ndone."
