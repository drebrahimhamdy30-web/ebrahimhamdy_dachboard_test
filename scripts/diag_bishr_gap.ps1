# diag_bishr_gap.ps1   (run on the MASTER)
#
# ONE question: do fh_id 42859..42939 exist in bishr's eplus?
#
#   They are absent from cashier_transactions at ANY date. The branch's sync
#   failed with network errors from 2026-11-16 01:16 until ~14:38 (13.5 h),
#   which is INSIDE the 24h catch-up window that re-runs every 5 minutes.
#   So either the sync lost them despite the window (a real, serious bug),
#   or eplus never issued those IDENTITY values (server restart / rollbacks)
#   and our "gap" is an illusion. Do not build a fix before knowing which.
#
# READ-ONLY. Nothing is written, no schema is touched.
#
# ASCII-only on purpose: a .ps1 with Arabic and no BOM is read as ANSI by
# PowerShell 5.1 and dies with a misleading "missing brace" error.
#
#   cd C:\phalix\dashboard ; git pull
#   powershell -ExecutionPolicy Bypass -File .\scripts\diag_bishr_gap.ps1

param(
  [string]$ConfigPath = "C:\phalix\sync_engine.json",
  [string]$Branch     = "bishr",
  [int]$GapFrom       = 42859,
  [int]$GapTo         = 42939,
  [int]$Days          = 14
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$cfg = $null
if (Test-Path $ConfigPath) {
  try { $cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch {}
}
if (-not $cfg) { Write-Host "STOP: cannot read $ConfigPath"; exit 1 }

$b = $cfg.branches.$Branch
if (-not $b -or -not $b.server) { Write-Host "STOP: no server for '$Branch' in config"; exit 1 }

# the sync engine's own read credentials, whatever they are called here
$user = $null; $pass = $null
foreach ($k in @('reader_user','user','sql_user','username','writer_user')) {
  if ($b.$k) { $user = $b.$k; break }
}
foreach ($k in @('reader_password','password','sql_password','writer_password')) {
  if ($b.$k) { $pass = $b.$k; break }
}
if (-not $user) { $user = Read-Host "SQL user for $Branch" }
if (-not $pass) {
  $s = Read-Host "password for $user" -AsSecureString
  $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}

Write-Host ("server : " + $b.server + "   user: " + $user)
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$user;Password=$pass;Connect Timeout=20")
try { $cn.Open() } catch { Write-Host ("connect FAILED: " + $_.Exception.Message); exit 1 }
Write-Host "connect: OK"
Write-Host ""

function Show($title, $sql) {
  Write-Host ("=== " + $title) -ForegroundColor Cyan
  try {
    $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 120
    $r = $c.ExecuteReader()
    while ($r.Read()) {
      $line = @()
      for ($i = 0; $i -lt $r.FieldCount; $i++) {
        $v = if ($r.IsDBNull($i)) { "NULL" } else { $r.GetValue($i).ToString() }
        $line += ($r.GetName($i) + "=" + $v)
      }
      Write-Host ("  " + ($line -join "  |  "))
    }
    $r.Close()
  } catch { Write-Host ("  ERROR: " + $_.Exception.Message) -ForegroundColor Red }
  Write-Host ""
}

# 1. THE question: are the 81 ids in eplus?
Show "1) the gap itself ($GapFrom..$GapTo)" @"
SELECT COUNT(*) AS rows_found, MIN(fh_id) AS lo, MAX(fh_id) AS hi,
       SUM(fh_value) AS total_value,
       MIN(sec_insert_date) AS first_at, MAX(sec_insert_date) AS last_at
  FROM F_Transaction_Header WHERE fh_id BETWEEN $GapFrom AND $GapTo
"@

# 2. were they deleted? eplus keeps deleted docs here
Show "2) deleted-records table for the same range" @"
SELECT COUNT(*) AS deleted_rows, MIN(fh_id) AS lo, MAX(fh_id) AS hi
  FROM F_Transaction_Header_SaveDeleteRecords WHERE fh_id BETWEEN $GapFrom AND $GapTo
"@

# 3. the neighbours - shows whether the sequence really jumps in eplus
Show "3) neighbours around the gap" @"
SELECT TOP 6 fh_id, fh_value, sec_insert_date, fh_computer
  FROM F_Transaction_Header WHERE fh_id < $GapFrom ORDER BY fh_id DESC
"@
Show "3b) first rows after the gap" @"
SELECT TOP 6 fh_id, fh_value, sec_insert_date, fh_computer
  FROM F_Transaction_Header WHERE fh_id > $GapTo ORDER BY fh_id ASC
"@

# 4. THE CONTROL: how complete is eplus's own id sequence?
#    If eplus itself skips ids routinely, then counting gaps in our copy
#    proves nothing and we need a different completeness measure.
Show "4) control: eplus own sequence over the last $Days days" @"
SELECT COUNT(*) AS rows_in_eplus, MIN(fh_id) AS lo, MAX(fh_id) AS hi,
       (MAX(fh_id) - MIN(fh_id) + 1) AS id_span,
       (MAX(fh_id) - MIN(fh_id) + 1) - COUNT(*) AS ids_never_used
  FROM F_Transaction_Header
 WHERE sec_insert_date >= DATEADD(day, -$Days, GETDATE())
"@

$cn.Close()
Write-Host "done - read-only, nothing was changed. Send me the whole output." -ForegroundColor Green
