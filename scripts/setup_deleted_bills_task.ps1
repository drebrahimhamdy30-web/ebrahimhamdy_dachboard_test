# Run ON THE MASTER as administrator (once) to schedule the deleted-bills sync.
# Reads all branches + Supabase service key from C:\phalix\sync_engine.json.
# Creates a scheduled task that runs every 30 minutes as SYSTEM.
param(
  [string]$RepoDir    = "C:\phalix\dashboard",
  [string]$ConfigPath = "C:\phalix\sync_engine.json",
  [int]$InitialDays   = 30
)
$ErrorActionPreference = 'Stop'
$script = Join-Path $RepoDir "scripts\sync_deleted_bills.ps1"
if (-not (Test-Path $script))     { throw "script not found: $script  (pull the prod repo into $RepoDir first)" }
if (-not (Test-Path $ConfigPath)) { throw "config not found: $ConfigPath" }

Write-Host "=== Initial backfill ($InitialDays days) ===" -ForegroundColor Cyan
& $script -ConfigPath $ConfigPath -Days $InitialDays

Write-Host "=== Creating scheduled task (every 30 min, SYSTEM) ===" -ForegroundColor Cyan
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" -ConfigPath `"$ConfigPath`" -Days 3"
schtasks /create /tn "phalix_deleted_bills_sync" /tr $tr /sc minute /mo 30 /ru SYSTEM /rl HIGHEST /f
Write-Host "Done. Task 'phalix_deleted_bills_sync' runs every 30 min." -ForegroundColor Green
