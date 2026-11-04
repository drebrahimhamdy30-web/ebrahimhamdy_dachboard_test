# diag_contract_diff.ps1 - compare contract bill numbers, eplus vs Supabase.
# READ-ONLY on both sides.
#
#   .\diag_contract_diff.ps1 -Branch all -Since 2026-06-01
#
# Answers two questions a count comparison cannot:
#   - in eplus, not with us  -> a real sync gap (invoices we never received)
#   - with us, not in eplus  -> rows we hold with no matching contract bill
#
# *** No month bucketing. ***  The first version filtered the Supabase side by
# month with a hardcoded +02:00 offset; Egypt runs on +03:00 from spring to
# autumn, so bills written in the first hours of a month fell outside the window
# and were reported missing while sitting in the table - five false positives
# out of six.  Comparing bill numbers over one open-ended range needs no offset
# arithmetic at all, so the bug cannot come back.
#
# ASCII-only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and mangles Arabic,
# breaking the parse with misleading errors.  The Arabic branch name is read
# from the branches table instead of being typed here.
param(
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json",
  [string]$Branch = "mamora",       # or "all"
  [string]$Since  = "2026-06-01"    # eplus side floor; our data starts late May
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$SBU = $cfg.supabaseUrl.TrimEnd('/')   # not $SB: $sb* would collide, names are case-insensitive
$H   = @{ apikey = $cfg.serviceKey; Authorization = "Bearer $($cfg.serviceKey)" }

function Get-Json($url) {
  return ((Invoke-WebRequest -Uri $url -Headers $H -UseBasicParsing).Content | ConvertFrom-Json)
}

if ($Branch -eq 'all') {
  foreach ($bk in $cfg.branches.PSObject.Properties.Name) {
    Write-Host ("`n================ {0} ================" -f $bk) -ForegroundColor Magenta
    & $PSCommandPath -ConfigPath $ConfigPath -Branch $bk -Since $Since
  }
  return
}

$brRow = Get-Json "$SBU/rest/v1/branches?select=name&code=eq.$Branch&limit=1"
if (-not $brRow -or $brRow.Count -eq 0) { throw "branch '$Branch' not found" }
$brAr = $brRow[0].name
Write-Host ("branch: {0}   since: {1}" -f $Branch, $Since) -ForegroundColor Cyan

# ---------- eplus ----------
$b = $cfg.branches.$Branch
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=25")
$cn.Open()
$c = $cn.CreateCommand(); $c.CommandTimeout = 900
$c.CommandText = "SELECT sth_id, total_bill, sth_flag, sec_insert_date FROM sales_trans_h " +
                 "WHERE sth_contract = 1 AND sec_insert_date >= '$Since'"
$r = $c.ExecuteReader()
$ep = @{}; $epDate = @{}
while ($r.Read()) {
  $k = [string][int64]$r['sth_id']
  $ep[$k] = [double]$r['total_bill']
  $epDate[$k] = ([datetime]$r['sec_insert_date']).ToString('yyyy-MM-dd')
}
$r.Close(); $cn.Close()
Write-Host ("eplus    : {0,5} contract bills   gross {1,12:N2}" -f $ep.Count, ($ep.Values | Measure-Object -Sum).Sum)

# ---------- Supabase: every row for this branch, no date filter ----------
$enc = [uri]::EscapeDataString($brAr)
$sbRows = @{}
$off = 0
while ($true) {
  $page = Get-Json "$SBU/rest/v1/contract_invoices?select=bill_no,total_bill&branch=eq.$enc&order=bill_no&limit=1000&offset=$off"
  if (-not $page -or $page.Count -eq 0) { break }
  foreach ($x in $page) { $sbRows[[string]$x.bill_no] = [double]$x.total_bill }
  $off += $page.Count
  if ($page.Count -lt 1000) { break }
}
Write-Host ("supabase : {0,5} rows (all dates)" -f $sbRows.Count)

# ---------- the gap that matters ----------
$missing = @($ep.Keys | Where-Object { -not $sbRows.ContainsKey($_) })
$mSum = if ($missing.Count) { (($missing | ForEach-Object { $ep[$_] }) | Measure-Object -Sum).Sum } else { 0 }

Write-Host ("`n>>> in eplus since {0}, NOT with us : {1} bill(s), gross {2:N2}" -f $Since, $missing.Count, $mSum) -ForegroundColor $(if ($missing.Count) { 'Red' } else { 'Green' })
$missing | Sort-Object | Select-Object -First 40 | ForEach-Object {
  Write-Host ("    {0}   {1,10:N2}   {2}" -f $_, $ep[$_], $epDate[$_])
}
Write-Host "`ndone."
