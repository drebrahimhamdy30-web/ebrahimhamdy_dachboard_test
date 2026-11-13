# wallet_disbursement_worker.ps1
# Processes pending rows in wallet_disbursement_queue (cloud) by writing a real
# eplus F_Transaction_Header disbursement: POS point (from) -> wallet account (to),
# amount = paid, note = "<bill_no>-<employee>", and updates both cash-store balances.
# Runs on the MASTER (all branches). SQL Server 2000. phalix_writer has INSERT/UPDATE.
#
# Default = DRY-RUN (does the write inside a transaction then ROLLBACK, touches nothing,
# and does NOT mark the queue). Use -Apply to commit and mark the queue done.
# ASCII-only script; the Arabic note is built from queue JSON (UTF-8) and sent as a VarChar param.
#
# Usage:
#   .\wallet_disbursement_worker.ps1 -Branch mamora            # dry-run preview
#   .\wallet_disbursement_worker.ps1 -Branch mamora -Apply     # execute for real

param(
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json",
  [string]$Branch = "mamora",
  [switch]$Apply,
  [int]$Uid = 1,                 # eplus sec_insert_uid for the automated disbursement
  [int]$Max = 50
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# pharmacy store id per branch (fh_cost_sto_id), same CASE as sync_jobs
$COST_STO = @{ mamora = 1; san = 26; bishr = 28; seyouf = 29 }

$cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
$SB = $cfg.supabaseUrl.TrimEnd('/')
$KEY = $cfg.serviceKey
$b = $cfg.branches.$Branch
if (-not $b) { Write-Host "no branch config for $Branch"; exit 1 }
if (-not $COST_STO.ContainsKey($Branch)) { Write-Host "no cost-store mapping for $Branch"; exit 1 }
$coststo = $COST_STO[$Branch]

$H = @{ apikey = $KEY; Authorization = "Bearer $KEY" }
function RestGet($path)   { Invoke-RestMethod -Method GET  -Uri "$SB/rest/v1/$path" -Headers $H }
function RestPatch($path, $body) {
  Invoke-RestMethod -Method PATCH -Uri "$SB/rest/v1/$path" -Headers ($H + @{ 'Content-Type'='application/json'; 'Prefer'='return=representation' }) -Body ($body | ConvertTo-Json -Compress)
}

$mode = if ($Apply) { "APPLY" } else { "DRY-RUN" }
Write-Host "== wallet disbursement worker ($mode) branch=$Branch ==" -ForegroundColor Cyan

$rows = RestGet "wallet_disbursement_queue?status=eq.pending&branch=eq.$Branch&select=*&order=id.asc&limit=$Max"
if (-not $rows -or $rows.Count -eq 0) { Write-Host "no pending rows."; exit 0 }
Write-Host ("pending: " + $rows.Count)

$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.writer_user);Password=$($b.writer_password);Connect Timeout=30")
$cn.Open()

function OneRow($v) { $r=$cn.CreateCommand(); $r.CommandText=$args[0] }

foreach ($row in $rows) {
  $id = [int]$row.id; $fh = [long]$row.fh_id
  $from = [int]$row.from_fcs_id; $to = [int]$row.resolved_to_fcs_id
  $val = [decimal]$row.paid
  $acct = ("" + $row.requested_by)
  $note = ("" + $row.bill_no + "-" + $row.employee + "-" + $acct)
  Write-Host ""
  Write-Host ("row id=$id fh=$fh  $from -> $to  val=$val  note=[$note]  channel=$($row.channel)") -ForegroundColor Yellow

  # ---- claim (APPLY only): pending -> processing, skip if someone else took it ----
  if ($Apply) {
    try {
      $claim = RestPatch "wallet_disbursement_queue?id=eq.$id&status=eq.pending" @{ status='processing' }
      if (-not $claim -or $claim.Count -eq 0) { Write-Host "  skipped (already claimed)"; continue }
    } catch { Write-Host "  claim failed: $($_.Exception.Message)"; continue }
  }

  try {
    # ---- safety re-check against live F_Cash_Store ----
    $chk = $cn.CreateCommand()
    $chk.CommandText = "SELECT (SELECT fcs_name_ar FROM F_Cash_Store WHERE fcs_id=@to) AS to_name, " +
                       "(SELECT fcs_type FROM F_Cash_Store WHERE fcs_id=@to) AS to_type, " +
                       "(SELECT fcs_active FROM F_Cash_Store WHERE fcs_id=@to) AS to_active, " +
                       "(SELECT COUNT(*) FROM F_Cash_Store WHERE fcs_id=@from) AS from_ok"
    $chk.Parameters.Add("@to",[System.Data.SqlDbType]::Int).Value = $to
    $chk.Parameters.Add("@from",[System.Data.SqlDbType]::Int).Value = $from
    $rd = $chk.ExecuteReader()
    $toName=$null;$toType=$null;$toActive=$null;$fromOk=0
    if ($rd.Read()) { $toName = "$($rd['to_name'])"; $toType="$($rd['to_type'])"; $toActive="$($rd['to_active'])"; $fromOk=[int]$rd['from_ok'] }
    $rd.Close()
    if ($fromOk -lt 1) { throw "from account $from not found" }
    if ("$toType" -ne "3") { throw "to account $to is not a cash-store (type=$toType)" }
    if ("$toActive" -ne "1") { throw "to account $to is not active" }
    if ($row.resolved_to_name -and ($toName.Trim() -ne ("" + $row.resolved_to_name).Trim())) {
      throw "to account name mismatch: eplus='$toName' expected='$($row.resolved_to_name)'"
    }
    if ($val -le 0) { throw "non-positive amount" }

    # ---- the write (INSERT + fh_code + both balances) ----
    $fin = if ($Apply) { "COMMIT" } else { "ROLLBACK" }
    $sql = @"
SET NOCOUNT ON;
DECLARE @newid bigint; DECLARE @err int;
SELECT 'before' AS phase, fcs_id, fcs_current_balance FROM F_Cash_Store WHERE fcs_id IN (@from,@to);
BEGIN TRAN;
INSERT INTO F_Transaction_Header
 (fh_trans_type, fh_trans_type2, fh_code, fh_value, fh_from_type, fh_from_id, fh_to_type, fh_to_id,
  fh_notes, fh_actual_date, fh_computer, fh_actual_cashier_id, fh_form_type,
  sec_insert_uid, sec_insert_date, sec_update_uid, sec_update_date, fh_sto_id, fh_cost_sto_id)
 VALUES (1,2,0,@val,3,@from,3,@to,@note,GETDATE(),'phalix',@from,0,@uid,GETDATE(),NULL,GETDATE(),0,@coststo);
SET @err=@@ERROR; IF @err<>0 BEGIN ROLLBACK; RAISERROR('insert failed',16,1); RETURN; END
SET @newid = CAST(SCOPE_IDENTITY() AS bigint);
UPDATE F_Transaction_Header SET fh_code=@newid WHERE fh_id=@newid;
SET @err=@@ERROR; IF @err<>0 BEGIN ROLLBACK; RAISERROR('code failed',16,1); RETURN; END
UPDATE F_Cash_Store SET fcs_current_balance = fcs_current_balance - @val WHERE fcs_id=@from;
SET @err=@@ERROR; IF @err<>0 BEGIN ROLLBACK; RAISERROR('from bal failed',16,1); RETURN; END
UPDATE F_Cash_Store SET fcs_current_balance = fcs_current_balance + @val WHERE fcs_id=@to;
SET @err=@@ERROR; IF @err<>0 BEGIN ROLLBACK; RAISERROR('to bal failed',16,1); RETURN; END
SELECT 'after' AS phase, fcs_id, fcs_current_balance FROM F_Cash_Store WHERE fcs_id IN (@from,@to);
$fin;
SELECT 'result' AS phase, @newid AS fcs_id, CAST(NULL AS money) AS fcs_current_balance;
"@
    $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 60
    $c.Parameters.Add("@from",[System.Data.SqlDbType]::Int).Value = $from
    $c.Parameters.Add("@to",[System.Data.SqlDbType]::Int).Value = $to
    $c.Parameters.Add("@val",[System.Data.SqlDbType]::Money).Value = $val
    $c.Parameters.Add("@note",[System.Data.SqlDbType]::VarChar,200).Value = $note
    $c.Parameters.Add("@uid",[System.Data.SqlDbType]::VarChar,50).Value = ("" + $Uid)
    $c.Parameters.Add("@coststo",[System.Data.SqlDbType]::Int).Value = $coststo
    $newfh = $null
    $r = $c.ExecuteReader()
    do { while ($r.Read()) {
      $p=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $x=if($r.IsDBNull($i)){'<null>'}else{$r.GetValue($i)}; $p+=("{0}={1}" -f $r.GetName($i),$x) }
      Write-Host ("    " + ($p -join " | "))
      if ("$($r.GetValue(0))" -eq "result") { $newfh = $r.GetValue(1) }
    } } while ($r.NextResult())
    $r.Close()

    if ($Apply) {
      RestPatch "wallet_disbursement_queue?id=eq.$id" @{ status='done'; eplus_fh_id=[long]$newfh; processed_at=(Get-Date).ToUniversalTime().ToString("o"); error=$null } | Out-Null
      Write-Host ("  DONE -> eplus fh_id=$newfh") -ForegroundColor Green
    } else {
      Write-Host ("  (dry-run: would create eplus fh_id ~ $newfh, rolled back)") -ForegroundColor DarkGray
    }
  }
  catch {
    $msg = $_.Exception.Message
    Write-Host ("  ERROR: $msg") -ForegroundColor Red
    if ($Apply) { try { RestPatch "wallet_disbursement_queue?id=eq.$id" @{ status='error'; error=$msg } | Out-Null } catch {} }
  }
}
$cn.Close()
Write-Host ""
Write-Host "done."
