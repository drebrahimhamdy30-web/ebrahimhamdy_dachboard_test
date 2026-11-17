# check_wallet_branch_ready.ps1   (run on the MASTER)
#
# Answers one question per branch: can the wallet-disbursement worker run here?
# READ-ONLY. The two permission probes run inside a transaction that is always
# rolled back, so nothing is ever written.
#
# It checks, per branch:
#   1. can phalix_writer connect to that branch's Genius?
#   2. does it have INSERT on F_Transaction_Header?   (the disbursement row)
#   3. does it have UPDATE on F_Cash_Store?           (the two balances)
#   4. lists the type-3 accounts (wallets + POS) with their fcs_id,
#      which is exactly what wallet_channel_map needs.
#
# ASCII-only on purpose: a .ps1 with Arabic and no BOM is read as ANSI by
# PowerShell 5.1 and breaks with a misleading "missing brace" error.
#
#   cd C:\phalix\dashboard ; git pull
#   powershell -ExecutionPolicy Bypass -File .\scripts\check_wallet_branch_ready.ps1

param(
  [string]$ConfigPath   = "C:\phalix\sync_engine.json",
  [string]$PasswordFile = "C:\phalix\rw.sec",
  [string]$KeyFile      = "C:\phalix\rw.key",
  [string[]]$Branches   = @('mamora','san','bishr','seyouf')
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$cfg = $null
if (Test-Path $ConfigPath) {
  try { $cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch {}
}
if (-not $cfg) { Write-Host "STOP: cannot read $ConfigPath"; exit 1 }

# writer password: encrypted file (same mechanism as the worker), else prompt
$pw = $null
if ((Test-Path $PasswordFile)) {
  $enc = (Get-Content $PasswordFile -Raw).Trim()
  $sec = if ((Test-Path $KeyFile)) { $enc | ConvertTo-SecureString -Key (Get-Content $KeyFile -Encoding Byte) } else { $enc | ConvertTo-SecureString }
  $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if ([string]::IsNullOrWhiteSpace($pw)) {
  $s = Read-Host "phalix_writer password" -AsSecureString
  $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}

$short = { param($m) ($m -replace '\s+',' ').Substring(0, [Math]::Min(80, ($m -replace '\s+',' ').Length)) }

foreach ($br in $Branches) {
  $b = $cfg.branches.$br
  Write-Host ""
  Write-Host ("=== " + $br + " ===") -ForegroundColor Cyan
  if (-not $b -or -not $b.server) { Write-Host "  no server in config" -ForegroundColor Yellow; continue }
  $wu = if ($b.writer_user) { $b.writer_user } else { 'phalix_writer' }
  Write-Host ("  server : " + $b.server + "   user: " + $wu)

  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$wu;Password=$pw;Connect Timeout=15")
  try { $cn.Open() } catch {
    Write-Host ("  connect: FAIL - " + (& $short $_.Exception.Message)) -ForegroundColor Red
    Write-Host "  -> phalix_writer probably does not exist on this server (SQL logins must be created locally)." -ForegroundColor Yellow
    continue
  }
  Write-Host "  connect: OK" -ForegroundColor Green

  $tx = $cn.BeginTransaction()
  foreach ($probe in @(
      @{ n = 'INSERT F_Transaction_Header';
         q = "INSERT INTO F_Transaction_Header (fh_trans_type,fh_trans_type2,fh_code,fh_value,fh_from_type,fh_from_id,fh_to_type,fh_to_id,fh_actual_date,fh_computer,fh_form_type,sec_insert_uid,sec_insert_date,sec_update_date,fh_sto_id,fh_cost_sto_id) VALUES (1,2,0,0.01,3,1,3,1,GETDATE(),'permtest',0,'1',GETDATE(),GETDATE(),0,1)" },
      @{ n = 'UPDATE F_Cash_Store';
         q = "UPDATE F_Cash_Store SET fcs_current_balance = fcs_current_balance WHERE 1 = 0" }
    )) {
    try {
      $c = $cn.CreateCommand(); $c.Transaction = $tx; $c.CommandText = $probe.q
      $c.ExecuteNonQuery() | Out-Null
      Write-Host ("  " + $probe.n + ": OK") -ForegroundColor Green
    } catch {
      Write-Host ("  " + $probe.n + ": NO - " + (& $short $_.Exception.Message)) -ForegroundColor Red
    }
  }
  try { $tx.Rollback() } catch {}
  Write-Host "  (both probes rolled back - nothing written)" -ForegroundColor DarkGray

  # type-3 accounts: these are the wallets and the POS points (fcs_id is what
  # wallet_channel_map stores - NOT fcs_code, they differ)
  try {
    $c = $cn.CreateCommand()
    $c.CommandText = "SELECT fcs_id, fcs_code, fcs_name_ar FROM F_Cash_Store WHERE fcs_type = 3 ORDER BY fcs_id"
    $r = $c.ExecuteReader()
    Write-Host "  type-3 accounts (fcs_id | fcs_code | name):"
    while ($r.Read()) {
      $nm = if ($r.IsDBNull(2)) { '' } else { $r.GetString(2) }
      Write-Host ("    {0,-5} | {1,-6} | {2}" -f $r.GetValue(0), $r.GetValue(1), $nm)
    }
    $r.Close()
  } catch { Write-Host ("  accounts: " + (& $short $_.Exception.Message)) -ForegroundColor Red }

  $cn.Close()
}
Write-Host ""
Write-Host "done. Send the output - the fcs_id list is what the channel map needs."
