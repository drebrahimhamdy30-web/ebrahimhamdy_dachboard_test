# resignal_customers.ps1 - re-send the eplus "Edit Customer" replication signal for given customers (runs on MASTER).
# Why: customer regions were set on the master without a replication signal, so branches never re-pulled
#      those customers (e.g. San Stefano misses the region for ~7,000 customers).
#      A signal row in Replication_Trans makes every branch re-pull the customer with all its delivery addresses.
#      Same row the Genius app writes and region_writeback.ps1 uses (confirmed working 2026-10-31).
# Safety: dry-run by default (prints only). Writes only with -Apply. Max 10 customers per run unless -Max is raised.
#         Skips customers that do not exist. No passwords in this file (encrypted files on the master).
# Run (dry):   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\resignal_customers.ps1 -Codes "141,145" -PasswordFile C:\phalix\rw.sec -KeyFile C:\phalix\rw.key
# Run (write): same + -Apply
# From file:   -CodesFile C:\phalix\region-missing.txt -Skip 0 -Max 200   (one code per line; -Skip = codes already done)
# ASCII-only on purpose (PowerShell 5.1 reads BOM-less files as ANSI).

param(
  [string]$Codes = "",
  [string]$CodesFile = "",
  [int]$Skip = 0,
  [int]$Max = 10,
  [switch]$Apply,
  [string]$Server = "localhost,1433",
  [string]$User = "phalix_writer",
  [System.Security.SecureString]$Password,
  [string]$PasswordFile,
  [string]$KeyFile,
  [string]$ReplUid = "1",
  [string]$LogFile = "C:\phalix\resignal_customers.log"
)
$ErrorActionPreference = "Stop"
function L($m) { $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; Write-Host $line; try { Add-Content -Path $LogFile -Value $line } catch {} }

# ---- codes
$list = @()
if ($Codes) { $list += $Codes.Split(',') }
if ($CodesFile) {
  if (-not (Test-Path $CodesFile)) { L "STOP: codes file not found: $CodesFile"; exit 1 }
  $list += Get-Content $CodesFile
}
$list = @($list | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
if ($Skip -gt 0) { $list = @($list | Select-Object -Skip $Skip) }
if ($list.Count -eq 0) { L "STOP: no customer codes."; exit 1 }
if ($list.Count -gt $Max) { L ("Limiting to first {0} of {1} codes (-Max)." -f $Max, $list.Count); $list = @($list | Select-Object -First $Max) }

# ---- password (encrypted file for scheduled runs, or prompt)
if (-not $Password -and $PasswordFile -and (Test-Path $PasswordFile)) {
  try {
    $enc = (Get-Content $PasswordFile -Raw).Trim()
    if ($KeyFile -and (Test-Path $KeyFile)) { $Password = $enc | ConvertTo-SecureString -Key (Get-Content $KeyFile -Encoding Byte) }
    else { $Password = $enc | ConvertTo-SecureString }
  } catch { L "STOP: cannot read encrypted password file."; exit 1 }
}
if (-not $Password) { $Password = Read-Host "phalix_writer password" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if ([string]::IsNullOrWhiteSpace($pw)) { L "STOP: empty password."; exit 1 }

$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=25")
$cn.Open()
function Scalar($sql, $params) { $c = $cn.CreateCommand(); $c.CommandText = $sql; if ($params) { foreach ($k in $params.Keys) { [void]$c.Parameters.AddWithValue($k, $params[$k]) } }; return $c.ExecuteScalar() }

$mode = if ($Apply) { "APPLY (writing signals)" } else { "DRY RUN (no writes) - add -Apply to write" }
L ("Start - {0} - {1} customers" -f $mode, $list.Count)

$done = 0; $missing = 0; $failed = 0
foreach ($code in $list) {
  $num = [decimal]$code
  $exists = Scalar "SELECT COUNT(*) FROM Customer WHERE cust_id=@c" @{ '@c' = $num }
  if ([int]$exists -eq 0) { L "  $code : customer not found - skipped"; $missing++; continue }
  if (-not $Apply) { L "  $code : would add Edit Customer signal"; continue }
  try {
    $id = Scalar "INSERT INTO Replication_Trans (trans_typ_1,trans_typ_2,store_id,itm_id,class_id,class_id_ext1,class_id_ext2,itm_qty,general_id,general_name,trans_qry,store_id2,itm_expire,sec_insert_date,sec_insert_uid,form_nm,ePlusVersion) VALUES (7,2,0,0,0,0,0,0,@g,'Edit Customer','',0,NULL,getdate(),@u,'Add_edit_customer_ar',NULL); SELECT @@IDENTITY" @{ '@g' = $num; '@u' = $ReplUid }
    L "  $code : signal added (trans_id=$id)"
    $done++
  } catch { L ("  $code : FAILED - " + $_.Exception.Message); $failed++ }
}
$cn.Close()
L ("Done - signals: {0}, not found: {1}, failed: {2}" -f $done, $missing, $failed)
