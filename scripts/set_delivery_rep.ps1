# set_delivery_rep.ps1
# Controlled test write for the delivery-rep writeback feature:
# set sales_deliv_info.deliv_emp_id (the "mandoob tawseel" column shown in the
# eplus "sales invoices" screen) to the real driver's Employee.e_id.
#
# ONE invoice per run. DRY-RUN by default (BEGIN TRAN ... ROLLBACK) so you can
# see exactly what would change before committing anything. Add -Apply to commit.
#
# Rules this script follows (owner's decisions, see memory delivery-rep-writeback):
#   * writes deliv_emp_id ONLY. deliv_emp_acc_id (the financial account) is never touched.
#   * refuses unless exactly ONE row matches the invoice.
#   * validates the target e_id exists in Employee before writing.
#   * sales are branch-local in eplus -> plain UPDATE, no Replication_Trans needed.
#
# Credentials: phalix_writer, same mechanism as the wallet worker / region writeback
#   -PasswordFile C:\phalix\rw.sec -KeyFile C:\phalix\rw.key
# (never put a password in this repo - the repos are public)
#
# Run ON THE MASTER (mamora = localhost). SQL Server 2000.
#
# Usage:
#   .\set_delivery_rep.ps1 -BillNo 1512875                      # inspect only
#   .\set_delivery_rep.ps1 -BillNo 1512875 -DriverEmpId 345      # dry-run the change
#   .\set_delivery_rep.ps1 -BillNo 1512875 -DriverEmpId 345 -Apply -PasswordFile C:\phalix\rw.sec -KeyFile C:\phalix\rw.key

param(
  [Parameter(Mandatory=$true)][string]$BillNo,
  [int]$DriverEmpId = 0,
  [string]$Branch = "mamora",
  [switch]$Apply,
  [string]$Server,                 # override, e.g. 192.168.192.100,1433
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json",
  [System.Security.SecureString]$Password,
  [string]$PasswordFile,
  [string]$KeyFile,
  [string]$WriterUser
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# ---- config / server ----
$cfg = $null
if (Test-Path $ConfigPath) {
  try { $cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch {}
}
$bcfg   = if ($cfg) { $cfg.branches.$Branch } else { $null }
$server = if ($Server) { $Server } elseif ($bcfg -and $bcfg.server) { $bcfg.server } else { "localhost,1433" }

# ---- creds: reading is enough to inspect; writing needs phalix_writer ----
if (-not $WriterUser) { $WriterUser = if ($bcfg -and $bcfg.writer_user) { $bcfg.writer_user } else { "phalix_writer" } }
if (-not $Password -and $PasswordFile -and (Test-Path $PasswordFile)) {
  $enc = (Get-Content $PasswordFile -Raw).Trim()
  if ($KeyFile -and (Test-Path $KeyFile)) { $Password = $enc | ConvertTo-SecureString -Key (Get-Content $KeyFile -Encoding Byte) }
  else { $Password = $enc | ConvertTo-SecureString }
}
$pw = $null
if ($Password) { $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)) }
elseif ($bcfg -and $bcfg.writer_password) { $pw = $bcfg.writer_password }
if ([string]::IsNullOrWhiteSpace($pw)) {
  $sec = Read-Host "$WriterUser password" -AsSecureString
  $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if ([string]::IsNullOrWhiteSpace($pw)) { L "STOP: no eplus password" Red; exit 1 }

$mode = if ($Apply) { "APPLY (commits)" } else { "DRY-RUN (rolls back)" }
L "== set delivery rep -- $mode ==" Cyan
L "   branch=$Branch  server=$server  user=$WriterUser  bill=$BillNo"

$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$server;Database=Genius;User ID=$WriterUser;Password=$pw;Connect Timeout=30")
try { $cn.Open() } catch { L "STOP: connect failed: $($_.Exception.Message)" Red; exit 1 }

function Q($sql, $params) {
  $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 60
  if ($params) { foreach ($k in $params.Keys) { [void]$c.Parameters.AddWithValue($k, $params[$k]) } }
  $t = New-Object System.Data.DataTable
  (New-Object System.Data.SqlClient.SqlDataAdapter($c)).Fill($t) | Out-Null
  # PowerShell unrolls a DataTable into its rows on output, so the caller gets
  # DataRow objects and ".Rows" comes back $null. Returning a comma-wrapped
  # array keeps it an array of rows, whatever the row count.
  return ,@($t.Rows)
}
function Scalar($sql, $params) {
  $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 60
  if ($params) { foreach ($k in $params.Keys) { [void]$c.Parameters.AddWithValue($k, $params[$k]) } }
  return $c.ExecuteScalar()
}

try {
  # ---- 1) the delivery row for this invoice --------------------------------
  $cur = Q "SELECT d.sth_id, d.deliv_emp_id, d.deliv_emp_acc_id, e.e_Name AS cur_name
            FROM sales_deliv_info d
            LEFT JOIN Employee e ON e.e_id = d.deliv_emp_id
            WHERE d.sth_id = @b" @{ '@b' = $BillNo }

  if ($cur.Count -eq 0) {
    # Diagnostics: "no row" almost always means we are on the wrong instance /
    # database, not that the invoice is missing. Say which box we actually hit.
    L "`nNo row in sales_deliv_info for sth_id=$BillNo." Yellow
    L "`nWhere am I really connected?" Yellow
    $d = Q "SELECT @@SERVERNAME AS srv, DB_NAME() AS db, @@VERSION AS ver"
    L ("   server  = " + $d[0]['srv'])
    L ("   db      = " + $d[0]['db'])
    L ("   version = " + ($d[0]['ver'] -split "`n")[0].Trim())
    $t = Q "SELECT COUNT(*) AS n, MIN(sth_id) AS lo, MAX(sth_id) AS hi FROM sales_deliv_info"
    L ("   sales_deliv_info rows = " + $t[0]['n'] + "   sth_id range: " + $t[0]['lo'] + " .. " + $t[0]['hi'])
    L "`n   newest 5 invoices in this table:" Yellow
    foreach ($row in (Q "SELECT TOP 5 sth_id, deliv_emp_id FROM sales_deliv_info ORDER BY sdi_id DESC")) {
      L ("     sth_id=" + $row['sth_id'] + "  deliv_emp_id=" + $row['deliv_emp_id'])
    }
    L "`n   columns (DataRow indexer, not property access):" Yellow
    foreach ($row in (Q "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='sales_deliv_info' ORDER BY ORDINAL_POSITION")) {
      L ("     " + $row['COLUMN_NAME'] + " (" + $row['DATA_TYPE'] + ")")
    }
    $cn.Close(); exit 2
  }
  if ($cur.Count -gt 1) {
    L "`nSTOP: $($cur.Count) rows match sth_id=$BillNo - refusing to touch any." Red
    $cn.Close(); exit 3
  }

  $r = $cur[0]
  $curId   = if ($r['deliv_emp_id'] -is [DBNull]) { "<null>" } else { $r['deliv_emp_id'] }
  $curName = if ($r['cur_name'] -is [DBNull])     { "<none>" } else { $r['cur_name'] }
  L "`nCurrent:" Cyan
  L "   deliv_emp_id     = $curId  ($curName)"
  L "   deliv_emp_acc_id = $(if ($r['deliv_emp_acc_id'] -is [DBNull]) { '<null>' } else { $r['deliv_emp_acc_id'] })   <- NOT touched"

  if ($DriverEmpId -le 0) { L "`n(no -DriverEmpId given: inspection only)" Yellow; $cn.Close(); exit 0 }

  # ---- 2) validate the target employee -------------------------------------
  $newName = Scalar "SELECT e_Name FROM Employee WHERE e_id = @d" @{ '@d' = $DriverEmpId }
  if (-not $newName) { L "`nSTOP: no Employee with e_id=$DriverEmpId" Red; $cn.Close(); exit 4 }
  L "`nTarget:"  Cyan
  L "   deliv_emp_id     = $DriverEmpId  ($newName)"
  if ("$curId" -eq "$DriverEmpId") { L "`nAlready set to this employee - nothing to do." Yellow; $cn.Close(); exit 0 }

  # ---- 3) the write, inside a transaction ----------------------------------
  $tx = $cn.BeginTransaction()
  try {
    $c = $cn.CreateCommand(); $c.Transaction = $tx; $c.CommandTimeout = 60
    $c.CommandText = "UPDATE sales_deliv_info SET deliv_emp_id = @d WHERE sth_id = @b"
    [void]$c.Parameters.AddWithValue('@d', $DriverEmpId)
    [void]$c.Parameters.AddWithValue('@b', $BillNo)
    $n = $c.ExecuteNonQuery()
    L "`nrows affected: $n"
    if ($n -ne 1) { throw "expected exactly 1 row, got $n - rolling back" }

    $c2 = $cn.CreateCommand(); $c2.Transaction = $tx; $c2.CommandTimeout = 60
    $c2.CommandText = "SELECT d.deliv_emp_id, e.e_Name, d.deliv_emp_acc_id
                       FROM sales_deliv_info d LEFT JOIN Employee e ON e.e_id = d.deliv_emp_id
                       WHERE d.sth_id = @b"
    [void]$c2.Parameters.AddWithValue('@b', $BillNo)
    $t2 = New-Object System.Data.DataTable
    (New-Object System.Data.SqlClient.SqlDataAdapter($c2)).Fill($t2) | Out-Null
    $a = $t2.Rows[0]
    L "After (inside the transaction):" Cyan
    L "   deliv_emp_id     = $($a['deliv_emp_id'])  ($($a['e_Name']))"
    L "   deliv_emp_acc_id = $(if ($a['deliv_emp_acc_id'] -is [DBNull]) { '<null>' } else { $a['deliv_emp_acc_id'] })"

    if ($Apply) { $tx.Commit();   L "`nCOMMITTED. Open the eplus sales-invoices screen and confirm." Green }
    else        { $tx.Rollback(); L "`nROLLED BACK (dry-run). Re-run with -Apply to commit." Yellow }
  } catch {
    try { $tx.Rollback() } catch {}
    L "`nSTOP: $($_.Exception.Message)" Red
    $cn.Close(); exit 5
  }
} finally { if ($cn.State -eq 'Open') { $cn.Close() } }
