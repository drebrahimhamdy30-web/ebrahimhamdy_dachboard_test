# grant_wallet_writer_system.ps1
# Grants phalix_writer what the wallet-disbursement worker needs on ONE branch:
#   GRANT SELECT, INSERT, UPDATE ON F_Transaction_Header   (the disbursement row + fh_code)
#   GRANT SELECT, UPDATE         ON F_Cash_Store           (the two balances)
#   GRANT SELECT                 ON Employee               (resolve the bill's user -> e_id)
#
# Runs as NT AUTHORITY\SYSTEM via a temporary scheduled task (same approach as
# grant_delivrep_writer_system.ps1) because the Windows user is not a SQL sysadmin.
# SQL Server 2000 syntax. phalix_writer login already exists -> grants only,
# no data is modified.
#
# MUST run LOCALLY ON THAT BRANCH'S SERVER, PowerShell "Run as Administrator".
# Remote execution does not work: schtasks /s is refused and Windows auth between
# the branch boxes times out or lands as Guest. (SQL *connections* work remotely;
# creating logins and granting does not.)
#
#   san    -> 192.168.192.225
#   bishr  -> 192.168.192.80
#   seyouf -> 192.168.192.44
#   mamora -> already granted
#
# Usage (on the branch server):
#   .\grant_wallet_writer_system.ps1

param([System.Security.SecureString]$WriterPassword)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m) { Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L "STOP: open PowerShell as Administrator first."; exit 1 }

$tmp = Join-Path $env:TEMP ("phx_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$sqlFile = Join-Path $tmp "grant.sql"
$batFile = Join-Path $tmp "run.bat"
$outFile = Join-Path $tmp "out.txt"

$sql = @"
USE Genius
GO
GRANT SELECT, INSERT, UPDATE ON F_Transaction_Header TO phalix_writer
GO
GRANT SELECT, UPDATE ON F_Cash_Store TO phalix_writer
GO
GRANT SELECT ON Employee TO phalix_writer
GO
SELECT 'wallets=' + CAST(COUNT(*) AS varchar(12)) FROM F_Cash_Store WHERE fcs_type = 3
GO
SELECT 'server=' + @@SERVERNAME + ' db=' + DB_NAME()
GO
"@
[IO.File]::WriteAllText($sqlFile, $sql, [Text.Encoding]::Default)
[IO.File]::WriteAllText($batFile, "osql -E -S . -i `"$sqlFile`" -o `"$outFile`"`r`n", [Text.Encoding]::ASCII)

$task = "phx_grant_" + (Get-Random -Maximum 99999)
try {
  L "Creating a temporary task that runs as SYSTEM..."
  & schtasks /create /tn $task /tr "`"$batFile`"" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f | Out-Null
  & schtasks /run /tn $task | Out-Null
  L "Running, waiting..."
  $waited = 0
  while (-not (Test-Path $outFile) -and $waited -lt 60) { Start-Sleep -Seconds 2; $waited += 2 }
  Start-Sleep -Seconds 3
  if (Test-Path $outFile) {
    L "osql output:"
    Get-Content $outFile | Where-Object { $_.Trim() } | ForEach-Object { "    $_" }
  } else { L "WARN: no output - the task probably did not run." }
} finally {
  & schtasks /delete /tn $task /f 2>$null | Out-Null
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  L "Temp task and files cleaned up."
}

# Independent check with the writer's own login: read the wallets, and prove the
# write permissions exist WITHOUT writing (everything inside a rolled-back tran).
if (-not $WriterPassword) { $WriterPassword = Read-Host "phalix_writer password to verify (Enter to skip)" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($WriterPassword))
if ([string]::IsNullOrWhiteSpace($pw)) { L "Skipped verify (no password). The grants above are what matters."; exit 0 }

try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=phalix_writer;Password=$pw;Connect Timeout=20")
  $cn.Open()
  $c = $cn.CreateCommand()
  $c.CommandText = "SELECT COUNT(*) FROM F_Cash_Store WHERE fcs_type = 3"
  L ("phalix_writer reads F_Cash_Store OK - type-3 accounts: " + $c.ExecuteScalar())

  $tx = $cn.BeginTransaction()
  $c2 = $cn.CreateCommand(); $c2.Transaction = $tx
  $c2.CommandText = "INSERT INTO F_Transaction_Header (fh_trans_type,fh_trans_type2,fh_code,fh_value,fh_from_type,fh_from_id,fh_to_type,fh_to_id,fh_actual_date,fh_computer,fh_form_type,sec_insert_uid,sec_insert_date,sec_update_date,fh_sto_id,fh_cost_sto_id) VALUES (1,2,0,0.01,3,1,3,1,GETDATE(),'permtest',0,'1',GETDATE(),GETDATE(),0,1)"
  $c2.ExecuteNonQuery() | Out-Null
  $c3 = $cn.CreateCommand(); $c3.Transaction = $tx
  $c3.CommandText = "UPDATE F_Cash_Store SET fcs_current_balance = fcs_current_balance WHERE 1 = 0"
  $c3.ExecuteNonQuery() | Out-Null
  $tx.Rollback()
  L "INSERT + UPDATE permissions OK (probe rolled back - nothing written)."

  L ""
  L "type-3 accounts (fcs_id | fcs_code | name) - this is what the channel map needs:"
  $c4 = $cn.CreateCommand()
  $c4.CommandText = "SELECT fcs_id, fcs_code, fcs_name_ar FROM F_Cash_Store WHERE fcs_type = 3 ORDER BY fcs_id"
  $r = $c4.ExecuteReader()
  while ($r.Read()) {
    $nm = if ($r.IsDBNull(2)) { '' } else { $r.GetString(2) }
    L ("    {0,-5} | {1,-6} | {2}" -f $r.GetValue(0), $r.GetValue(1), $nm)
  }
  $r.Close()
  $cn.Close()
} catch {
  L ("verify failed: " + $_.Exception.Message)
  exit 1
}
