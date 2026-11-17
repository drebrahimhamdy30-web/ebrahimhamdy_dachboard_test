# grant_wallet_writer_system.ps1
# Grants phalix_writer what the wallet-disbursement worker needs on ONE branch:
#   GRANT SELECT, INSERT, UPDATE ON F_Transaction_Header   (the disbursement row + fh_code)
#   GRANT SELECT, UPDATE         ON F_Cash_Store           (the two balances)
#   GRANT SELECT                 ON Employee               (resolve the bill's user -> e_id)
#
# Two ways in, tried in order:
#   1. DIRECT, as the logged-in Windows user. On many of these boxes the local
#      Administrators group is already sysadmin in SQL, and then nothing else is
#      needed. Errors are immediate and readable.
#   2. SYSTEM, via a temporary scheduled task. Needed where the Windows user is
#      NOT sysadmin (the SQL service runs as LocalSystem, so SYSTEM is). The
#      first version only did this, and when the task silently refused to run
#      there was nothing to look at - so now the task's own status and last
#      result are printed, and the temp folder is kept when it fails.
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
# No data is modified: GRANT only, plus a permission probe that is rolled back.

param(
  [System.Security.SecureString]$WriterPassword,
  [string]$SqlServer = "localhost,1433"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m, $c = "Gray") { Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor $c }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L "STOP: open PowerShell as Administrator first." Red; exit 1 }

$GRANTS = @(
  "GRANT SELECT, INSERT, UPDATE ON F_Transaction_Header TO phalix_writer",
  "GRANT SELECT, UPDATE ON F_Cash_Store TO phalix_writer",
  "GRANT SELECT ON Employee TO phalix_writer"
)

# ---------- attempt 1: direct, as the current Windows user ----------
L "Trying directly as the logged-in Windows user..." Cyan
$granted = $false
try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServer;Database=Genius;Integrated Security=SSPI;Connect Timeout=15")
  $cn.Open()
  $who = $cn.CreateCommand(); $who.CommandText = "SELECT SUSER_SNAME(), @@SERVERNAME, DB_NAME()"
  $r = $who.ExecuteReader(); $r.Read()
  L ("  connected as: " + $r.GetValue(0) + "   server: " + $r.GetValue(1) + "   db: " + $r.GetValue(2))
  $r.Close()
  foreach ($g in $GRANTS) {
    $c = $cn.CreateCommand(); $c.CommandText = $g
    $c.ExecuteNonQuery() | Out-Null
    L ("  OK  " + $g) Green
  }
  $granted = $true
  $cn.Close()
} catch {
  L ("  direct grant failed: " + ($_.Exception.Message -replace '\s+',' ')) Yellow
  try { if ($cn -and $cn.State -eq 'Open') { $cn.Close() } } catch {}
}

# ---------- attempt 2: as SYSTEM, via a temporary scheduled task ----------
if (-not $granted) {
  L ""
  L "Falling back to a temporary task running as SYSTEM..." Cyan
  # C:\Windows\Temp, not the user's TEMP: SYSTEM owns it and it has no spaces.
  # A path like "C:\Users\New PC\AppData\Local\Temp" broke this silently.
  $tmp = Join-Path $env:SystemRoot ("Temp\phx_" + [guid]::NewGuid().ToString("N").Substring(0,8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $sqlFile = Join-Path $tmp "grant.sql"
  $batFile = Join-Path $tmp "run.bat"
  $outFile = Join-Path $tmp "out.txt"

  $sql = "USE Genius" + "`r`nGO`r`n" + (($GRANTS | ForEach-Object { $_ + "`r`nGO" }) -join "`r`n") + "`r`n"
  [IO.File]::WriteAllText($sqlFile, $sql, [Text.Encoding]::Default)

  # osql ships with SQL 2000; newer installs only have sqlcmd. Try both, and
  # always write something, so a silent failure is still visible.
  $bat = "@echo off`r`n" +
         "echo === start %DATE% %TIME% === > `"$outFile`"`r`n" +
         "osql -E -S . -i `"$sqlFile`" >> `"$outFile`" 2>&1`r`n" +
         "if errorlevel 1 echo [osql missing or failed] >> `"$outFile`"`r`n" +
         "sqlcmd -E -S . -i `"$sqlFile`" >> `"$outFile`" 2>&1`r`n" +
         "if errorlevel 1 echo [sqlcmd missing or failed] >> `"$outFile`"`r`n" +
         "echo === end === >> `"$outFile`"`r`n"
  [IO.File]::WriteAllText($batFile, $bat, [Text.Encoding]::ASCII)

  $task = "phx_grant_" + (Get-Random -Maximum 99999)
  $ok = $false
  try {
    & schtasks /create /tn $task /tr "`"$batFile`"" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f
    if ($LASTEXITCODE -ne 0) { L "  schtasks /create failed." Red }
    & schtasks /run /tn $task
    if ($LASTEXITCODE -ne 0) { L "  schtasks /run failed." Red }
    $waited = 0
    while (-not (Test-Path $outFile) -and $waited -lt 45) { Start-Sleep -Seconds 2; $waited += 2 }
    Start-Sleep -Seconds 2
    if (Test-Path $outFile) {
      $ok = $true
      L "  task output:"
      Get-Content $outFile | Where-Object { $_.Trim() } | ForEach-Object { "      $_" }
    } else {
      L "  no output file. Task status:" Yellow
      & schtasks /query /tn $task /v /fo LIST | Select-String "Status|Last Result|Last Run|Run As User"
      L ("  the bat and sql were left in: " + $tmp) Yellow
      L "  you can run it by hand to see the error:" Yellow
      L ("    " + $batFile) Yellow
    }
  } finally {
    & schtasks /delete /tn $task /f 2>$null | Out-Null
    if ($ok) { try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
  }
}

# ---------- verify with the writer's own login ----------
L ""
if (-not $WriterPassword) { $WriterPassword = Read-Host "phalix_writer password to verify (Enter to skip)" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($WriterPassword))
if ([string]::IsNullOrWhiteSpace($pw)) { L "Skipped verify (no password)."; exit 0 }

try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServer;Database=Genius;User ID=phalix_writer;Password=$pw;Connect Timeout=20")
  $cn.Open()
  $c = $cn.CreateCommand()
  $c.CommandText = "SELECT COUNT(*) FROM F_Cash_Store WHERE fcs_type = 3"
  L ("phalix_writer reads F_Cash_Store OK - type-3 accounts: " + $c.ExecuteScalar()) Green

  $tx = $cn.BeginTransaction()
  $c2 = $cn.CreateCommand(); $c2.Transaction = $tx
  $c2.CommandText = "INSERT INTO F_Transaction_Header (fh_trans_type,fh_trans_type2,fh_code,fh_value,fh_from_type,fh_from_id,fh_to_type,fh_to_id,fh_actual_date,fh_computer,fh_form_type,sec_insert_uid,sec_insert_date,sec_update_date,fh_sto_id,fh_cost_sto_id) VALUES (1,2,0,0.01,3,1,3,1,GETDATE(),'permtest',0,'1',GETDATE(),GETDATE(),0,1)"
  $c2.ExecuteNonQuery() | Out-Null
  $c3 = $cn.CreateCommand(); $c3.Transaction = $tx
  $c3.CommandText = "UPDATE F_Cash_Store SET fcs_current_balance = fcs_current_balance WHERE 1 = 0"
  $c3.ExecuteNonQuery() | Out-Null
  $tx.Rollback()
  L "INSERT + UPDATE permissions OK (probe rolled back - nothing written)." Green

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
  L ("verify failed: " + ($_.Exception.Message -replace '\s+',' ')) Red
  exit 1
}
