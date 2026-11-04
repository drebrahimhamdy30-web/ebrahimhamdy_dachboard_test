# recover_contract_bills.ps1 - pull named contract bills from eplus into
# contract_invoices, using the SAME path the saved_contracts job uses.
# ASCII-only (PowerShell 5.1 mangles a BOM-less Arabic .ps1).
#
# Why not a hand-written INSERT: the job already maps store->branch, looks the
# customer name up from `customers`, and decides pos_status from sth_flag.
# Re-implementing that by hand would drift from it.  So we do exactly what the
# job does: read with its SELECT -> push to contract_backfill_stage -> call
# apply_saved_contracts(), which inserts ON CONFLICT DO NOTHING and truncates
# the stage.  Nothing existing can be overwritten.
#
# Default is a dry run; pass -Apply to write.
param(
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json",
  [string]$Branch = "mamora",
  [string[]]$Bills = @('1378703','1401935','1426570','1451850','1451857','1503183'),
  [switch]$Apply
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$SBU = $cfg.supabaseUrl.TrimEnd('/')          # not $SB: $sb* would collide (case-insensitive)
$H   = @{ apikey = $cfg.serviceKey; Authorization = "Bearer $($cfg.serviceKey)" }

$idList = ($Bills | ForEach-Object { [int64]$_ }) -join ','
Write-Host ("branch={0}  bills={1}" -f $Branch, $Bills.Count) -ForegroundColor Cyan

# ---- 1) read from eplus with the job's own SELECT ----
$b = $cfg.branches.$Branch
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=25")
$cn.Open()
$c = $cn.CreateCommand(); $c.CommandTimeout = 300
$c.CommandText = @"
SELECT '$Branch' AS branch_code, s.sto_name_ar AS store_name, h.sth_id, h.cust_id,
       h.total_bill, h.total_bill_net, e.e_Name AS employee_name, h.sth_flag,
       h.bill_typ, h.sec_insert_date AS bill_date, h.sth_contract
FROM sales_trans_h h
LEFT JOIN Store s    ON s.sto_id = h.sto_id
LEFT JOIN Employee e ON e.e_id  = h.emp_id
WHERE h.sth_id IN ($idList)
"@
$r = $c.ExecuteReader()
$rows = New-Object System.Collections.ArrayList
while ($r.Read()) {
  if ([int]$r['sth_contract'] -ne 1) {
    Write-Host ("  SKIP {0}: not a contract bill in eplus" -f $r['sth_id']) -ForegroundColor Red
    continue
  }
  [void]$rows.Add([ordered]@{
    branch_code    = $Branch
    store_name     = $r['store_name']
    sth_id         = [int64]$r['sth_id']
    cust_id        = [int64]$r['cust_id']
    total_bill     = [double]$r['total_bill']
    total_bill_net = [double]$r['total_bill_net']
    employee_name  = $r['employee_name']
    sth_flag       = [string]$r['sth_flag']
    bill_typ       = [int]$r['bill_typ']
    bill_date      = ([datetime]$r['bill_date']).ToString('yyyy-MM-ddTHH:mm:ss')
  })
  Write-Host ("  {0}  {1,10:N2}  flag={2}  {3}" -f $r['sth_id'], [double]$r['total_bill'], $r['sth_flag'], $r['store_name'])
}
$r.Close(); $cn.Close()

if ($rows.Count -ne $Bills.Count) {
  Write-Host ("  WARNING: asked for {0}, eplus returned {1}" -f $Bills.Count, $rows.Count) -ForegroundColor Yellow
}
if ($rows.Count -eq 0) { Write-Host "nothing to do."; return }

if (-not $Apply) { Write-Host "`n(dry run - pass -Apply to write)" -ForegroundColor DarkGray; return }

# ---- 2) the stage must be empty, or we would apply someone else's rows ----
$st = (Invoke-WebRequest -Uri "$SBU/rest/v1/contract_backfill_stage?select=sth_id&limit=1" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json
if ($st -and $st.Count -gt 0) {
  Write-Host "  the stage table is busy (the hourly job is mid-run) - try again in a minute" -ForegroundColor Red
  return
}

# ---- 3) push + apply, exactly like the job does ----
$hw = $H.Clone(); $hw['Content-Type'] = 'application/json'; $hw['Prefer'] = 'resolution=merge-duplicates,return=minimal'
$body = ConvertTo-Json @($rows) -Depth 4 -Compress
Invoke-RestMethod -Method Post -Uri "$SBU/rest/v1/contract_backfill_stage?on_conflict=branch_code,sth_id" `
                  -Headers $hw -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
Write-Host ("  staged {0} row(s)" -f $rows.Count) -ForegroundColor Green

$hr = $H.Clone(); $hr['Content-Type'] = 'application/json'
$res = Invoke-RestMethod -Method Post -Uri "$SBU/rest/v1/rpc/apply_saved_contracts" -Headers $hr -Body ([Text.Encoding]::UTF8.GetBytes('{}'))
Write-Host ("  apply_saved_contracts -> inserted={0}" -f $res.inserted) -ForegroundColor Green

# ---- 4) prove each one landed ----
Write-Host "`nverifying:" -ForegroundColor Cyan
foreach ($id in $Bills) {
  $u = "$SBU/rest/v1/contract_invoices?select=bill_no,branch,pos_status,total_bill&bill_no=eq.$id"
  $got = (Invoke-WebRequest -Uri $u -Headers $H -UseBasicParsing).Content | ConvertFrom-Json
  if ($got -and $got.Count -gt 0) {
    Write-Host ("  OK   {0}  {1}  {2}  {3}" -f $id, $got[0].branch, $got[0].pos_status, $got[0].total_bill) -ForegroundColor Green
  } else {
    Write-Host ("  MISS {0} - still not there" -f $id) -ForegroundColor Red
  }
}
Write-Host "`ndone."
