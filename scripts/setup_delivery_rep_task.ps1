# setup_delivery_rep_task.ps1  (run on the MASTER, as Administrator)
# Installs the delivery-rep sweep as a scheduled task that runs every 10 minutes
# as NT AUTHORITY\SYSTEM, reusing the SAME credential mechanism as the wallet worker:
#   - phalix_writer password: encrypted file C:\phalix\rw.sec  (+ AES key C:\phalix\rw.key)
#   - Supabase service_role key: machine env var SUPABASE_SERVICE_KEY
#   - eplus server + branch: from C:\phalix\sync_engine.json (mamora -> localhost)
#
# It FIRST runs a dry-run self-check (connects to eplus + cloud, NO write) and only
# schedules if that succeeds. ASCII-only.
#
# `/sc minute /mo N` is used on purpose: a TimeTrigger with Repetition+Duration
# +StopAtDurationEnd is a one-shot countdown that silently stops re-arming - that
# is what froze the sync engine for days once.
#
#   cd C:\phalix\dashboard ; git pull
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup_delivery_rep_task.ps1

param(
  [string]$Branch       = "mamora",
  [string]$RepoPath     = "C:\phalix\dashboard",
  [string]$ConfigPath   = "C:\phalix\sync_engine.json",
  [string]$PasswordFile = "C:\phalix\rw.sec",
  [string]$KeyFile      = "C:\phalix\rw.key",
  [int]$Minutes         = 10,
  [int]$Hours           = 24,
  [string]$LogPath      = "C:\phalix\delivery_rep.log",
  [string]$TaskName     = "phalix_delivery_rep"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "STOP: open PowerShell as Administrator first."; exit 1 }

$worker = Join-Path $RepoPath "scripts\sync_delivery_rep.ps1"
foreach ($p in @($worker,$ConfigPath,$PasswordFile,$KeyFile)) {
  if (-not (Test-Path $p)) { Write-Host "STOP: not found: $p"; exit 1 }
}
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("SUPABASE_SERVICE_KEY","Machine"))) {
  Write-Host "STOP: machine env var SUPABASE_SERVICE_KEY is not set (same one the wallet task uses)."; exit 1
}

Write-Host "== dry-run self-check (connects to eplus + cloud, no write) ==" -ForegroundColor Cyan
$env:SUPABASE_SERVICE_KEY = [Environment]::GetEnvironmentVariable("SUPABASE_SERVICE_KEY","Machine")
& powershell -NoProfile -ExecutionPolicy Bypass -File $worker -Branch $Branch -Hours $Hours `
    -ConfigPath $ConfigPath -PasswordFile $PasswordFile -KeyFile $KeyFile
if ($LASTEXITCODE -ne 0) { Write-Host ("STOP: dry-run failed (exit {0}). Fix creds/connectivity before scheduling." -f $LASTEXITCODE); exit 1 }
Write-Host "dry-run OK." -ForegroundColor Green

# scheduled task as SYSTEM (SYSTEM decrypts rw.sec via rw.key and sees the machine env var)
$action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$worker`" -Branch $Branch -Hours $Hours " +
          "-ConfigPath `"$ConfigPath`" -PasswordFile `"$PasswordFile`" -KeyFile `"$KeyFile`" -LogPath `"$LogPath`" -Apply"
& schtasks /create /tn $TaskName /tr $action /sc minute /mo $Minutes /ru SYSTEM /rl HIGHEST /f | Out-Null

& schtasks /query /tn $TaskName /fo LIST | Select-String "TaskName|Status|Next Run"
Write-Host ""
Write-Host ("run it once now with:  schtasks /run /tn {0}" -f $TaskName)
Write-Host ("last result:           schtasks /query /tn {0} /v /fo LIST | Select-String `"Last Result|Last Run`"" -f $TaskName)
Write-Host ("log:                   {0}" -f $LogPath)
Write-Host ("remove:                schtasks /delete /tn {0} /f" -f $TaskName)
