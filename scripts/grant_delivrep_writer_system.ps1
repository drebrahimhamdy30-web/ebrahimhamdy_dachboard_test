# grant_delivrep_writer_system.ps1
# Grants phalix_writer the permissions needed to edit the delivery rep on
# sales invoices (delivery-rep writeback feature):
#   GRANT SELECT, UPDATE ON sales_deliv_info   (write deliv_emp_id = real driver's e_id)
#   GRANT SELECT          ON Employee           (validate the e_id's name)
# sales_trans_h SELECT is already granted (create_writer.ps1).
#
# Runs as NT AUTHORITY\SYSTEM via a temporary scheduled task (same approach as
# grant_region_writer_system.ps1) because the Windows user is not a SQL sysadmin.
# SQL Server 2000 syntax. phalix_writer login already exists -> grants only,
# no data is modified.
#
# MUST run ON THE MASTER server (192.168.192.100), PowerShell "Run as Administrator".
# Usage:  .\grant_delivrep_writer_system.ps1

param([System.Security.SecureString]$WriterPassword)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m){ Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

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
GRANT SELECT, UPDATE ON sales_deliv_info TO phalix_writer
GO
GRANT SELECT ON Employee TO phalix_writer
GO
SELECT 'deliv_rows=' + CAST(COUNT(*) AS varchar(12)) FROM sales_deliv_info
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

# Optional independent check: can the writer read + update sales_deliv_info (no-op)?
if (-not $WriterPassword) { $WriterPassword = Read-Host "phalix_writer password to verify (Enter to skip)" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($WriterPassword))
if ([string]::IsNullOrWhiteSpace($pw)) { L "Skipped verify (no password). The grants above are what matters."; exit 0 }
try {
  $cn = New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=phalix_writer;Password=$pw;Connect Timeout=20")
  $cn.Open()
  $c = $cn.CreateCommand()
  $c.CommandText = "SELECT COUNT(*) FROM sales_deliv_info"
  L ("phalix_writer reads sales_deliv_info OK - rows: " + $c.ExecuteScalar())
  $c.CommandText = "BEGIN TRAN; UPDATE sales_deliv_info SET deliv_emp_id = deliv_emp_id WHERE 1=0; ROLLBACK;"
  [void]$c.ExecuteNonQuery()
  L "UPDATE permission on sales_deliv_info works OK"
  $cn.Close()
} catch {
  L "Verify failed: $($_.Exception.Message)"
  L "If 'Login failed' the password is wrong or the task did not run as SYSTEM - send me the osql output above."
}
