# sync_delivery_rep.ps1
# Writes the real driver into the eplus "delivery rep" column for every order
# that was delivered:  sales_deliv_info.deliv_emp_id = drivers.eplus_emp_id
#
# A SWEEP, not a queue. The write is idempotent (one assignment, not a financial
# movement), so re-running is free and a failed run heals itself on the next one.
# No extra table, no state to go stale.
#
# Source of truth: cloud RPC delivery_rep_pending(branch, hours) -> orders with
#   delivered_at IS NOT NULL  +  bill_no  +  a driver mapped to an eplus e_id.
#   ("delivered_at is not null" IS "tam el-tawseel": the order sits in status
#    'delivered' for ~30 min then flips to 'completed', so filtering on status
#    would miss almost everything.)
#
# Rules (owner's decisions - see memory delivery-rep-writeback):
#   * writes deliv_emp_id ONLY. deliv_emp_acc_id is never touched.
#   * sec_update_date / sec_update_uid are left alone (option A, 2026-11-15).
#   * only rows whose current value differs are written.
#   * DRY-RUN by default; -Apply commits.
#
# Usage:
#   .\sync_delivery_rep.ps1                                   # dry-run, last 24h
#   .\sync_delivery_rep.ps1 -Hours 240                        # dry-run, last 10 days
#   .\sync_delivery_rep.ps1 -Apply -PasswordFile C:\phalix\rw.sec -KeyFile C:\phalix\rw.key
#
# Scheduled (every 10 min, as SYSTEM, same pattern as phalix_wallet_disb).

param(
  [string]$Branch = "mamora",
  [int]$Hours = 24,
  [switch]$Apply,
  [int]$Max = 20000,
  [string]$Server,
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json",
  [System.Security.SecureString]$Password,
  [string]$PasswordFile,
  [string]$KeyFile,
  [string]$WriterUser,
  [string]$SbUrl,
  [string]$SbKey = $env:SUPABASE_SERVICE_KEY,
  [string]$LogPath
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function L($m, $c = "Gray") {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line -ForegroundColor $c
  # UTF-8 explicitly: Add-Content writes ANSI and turns Arabic into question marks
  if ($LogPath) { try { [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $utf8NoBom) } catch {} }
}

# ---- config ----
$cfg = $null
if (Test-Path $ConfigPath) {
  try { $cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch {}
}
$bcfg   = if ($cfg) { $cfg.branches.$Branch } else { $null }
$server = if ($Server) { $Server } elseif ($bcfg -and $bcfg.server) { $bcfg.server } else { "localhost,1433" }

if (-not $SbKey -and $cfg) { $SbKey = $cfg.serviceKey }
if ([string]::IsNullOrWhiteSpace($SbKey)) { L "STOP: no service key (set `$env:SUPABASE_SERVICE_KEY or config.serviceKey)" Red; exit 1 }
if (-not $SbUrl) { $SbUrl = if ($cfg -and $cfg.supabaseUrl) { $cfg.supabaseUrl } else { "https://rxtjoqulmgkkcohmgzgi.supabase.co" } }
$SB = $SbUrl.TrimEnd('/')

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
if ([string]::IsNullOrWhiteSpace($pw)) { L "STOP: no eplus writer password" Red; exit 1 }

$mode = if ($Apply) { "APPLY" } else { "DRY-RUN" }
L "== delivery rep sweep ($mode) branch=$Branch hours=$Hours  (eplus: $WriterUser@$server) ==" Cyan

# ---- 1) what should be written (cloud) -----------------------------------
$H = @{ apikey = $SbKey; Authorization = "Bearer $SbKey"; 'Content-Type' = 'application/json' }
try {
  $want = Invoke-RestMethod -Method POST -Uri "$SB/rest/v1/rpc/delivery_rep_pending" -Headers $H `
            -Body (@{ p_branch = $Branch; p_hours = $Hours; p_limit = $Max } | ConvertTo-Json -Compress)
} catch { L "STOP: cloud read failed: $($_.Exception.Message)" Red; exit 1 }
if (-not $want -or $want.Count -eq 0) { L "nothing delivered in the window - done." Green; exit 0 }
L ("delivered orders with a mapped driver: " + $want.Count)

# bill_no must be numeric: it goes into an IN (...) list, and a non-numeric one
# would both break the query and be a hole for injection.
$bad  = @($want | Where-Object { $_.bill_no -notmatch '^\d+$' })
$want = @($want | Where-Object { $_.bill_no -match '^\d+$' })
if ($bad.Count) { L ("skipped (bill_no not numeric): " + $bad.Count + " -> " + (($bad | Select-Object -First 5 | ForEach-Object { $_.bill_no }) -join ',')) Yellow }
if (-not $want.Count) { L "nothing usable - done." Yellow; exit 0 }

# ---- 2) what eplus has now ------------------------------------------------
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$server;Database=Genius;User ID=$WriterUser;Password=$pw;Connect Timeout=30")
try { $cn.Open() } catch { L "STOP: eplus connect failed ($WriterUser@$server): $($_.Exception.Message)" Red; exit 1 }

function Rows($sql) {
  $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 120
  $t = New-Object System.Data.DataTable
  (New-Object System.Data.SqlClient.SqlDataAdapter($c)).Fill($t) | Out-Null
  # the comma keeps PowerShell from unrolling the table into loose DataRows
  return ,@($t.Rows)
}

$have = @{}
$ids  = @($want | ForEach-Object { $_.bill_no })
for ($i = 0; $i -lt $ids.Count; $i += 500) {
  $chunk = $ids[$i..([Math]::Min($i + 499, $ids.Count - 1))] -join ','
  foreach ($row in (Rows "SELECT sth_id, deliv_emp_id FROM sales_deliv_info WHERE sth_id IN ($chunk)")) {
    $have["$($row['sth_id'])"] = $(if ($row['deliv_emp_id'] -is [DBNull]) { $null } else { [int]$row['deliv_emp_id'] })
  }
}
L ("found in eplus: " + $have.Count + " of " + $want.Count)

# ---- 3) diff ---------------------------------------------------------------
$todo = @(); $ok = 0; $missing = 0
foreach ($w in $want) {
  if (-not $have.ContainsKey($w.bill_no)) { $missing++; continue }   # invoice not on this server
  if ($have[$w.bill_no] -eq [int]$w.emp_id) { $ok++; continue }      # already right
  $todo += $w
}
L ("already correct: $ok   to write: $($todo.Count)   invoice not found in eplus: $missing")
if ($todo.Count -eq 0) { L "nothing to do." Green; $cn.Close(); exit 0 }

$todo | Select-Object -First 10 | ForEach-Object {
  L ("   bill " + $_.bill_no + ": " + $(if ($null -eq $have[$_.bill_no]) { '<null>' } else { $have[$_.bill_no] }) + " -> " + $_.emp_id + "  (" + $_.driver + ")")
}
if ($todo.Count -gt 10) { L ("   ... and " + ($todo.Count - 10) + " more") }

if (-not $Apply) { L "`nDRY-RUN: nothing written. Re-run with -Apply." Yellow; $cn.Close(); exit 0 }

# ---- 4) write --------------------------------------------------------------
# One statement per row, committed as it goes: a partial run leaves correct rows
# correct, and the next sweep picks up whatever is left.
$done = 0; $fail = 0
$cmd = $cn.CreateCommand()
$cmd.CommandText = "UPDATE sales_deliv_info SET deliv_emp_id = @d WHERE sth_id = @b"
$cmd.CommandTimeout = 60
[void]$cmd.Parameters.Add("@d", [System.Data.SqlDbType]::Decimal)
[void]$cmd.Parameters.Add("@b", [System.Data.SqlDbType]::Decimal)
foreach ($w in $todo) {
  try {
    $cmd.Parameters["@d"].Value = [decimal]$w.emp_id
    $cmd.Parameters["@b"].Value = [decimal]$w.bill_no
    $n = $cmd.ExecuteNonQuery()
    if ($n -eq 1) { $done++ } else { $fail++; L ("   bill $($w.bill_no): expected 1 row, got $n") Yellow }
  } catch { $fail++; L ("   bill $($w.bill_no) failed: $($_.Exception.Message)") Red }
}
L ("written: $done   failed: $fail") $(if ($fail) { "Yellow" } else { "Green" })
$cn.Close()
