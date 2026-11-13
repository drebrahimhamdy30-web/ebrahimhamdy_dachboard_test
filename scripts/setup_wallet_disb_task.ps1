# setup_wallet_disb_task.ps1  (run on the MASTER, as Administrator)
# Installs the wallet-disbursement worker as a scheduled task that runs every minute.
# It FIRST does a dry-run self-check (connects to cloud + eplus, no write) and only
# schedules if that succeeds. ASCII-only.
#
#   cd C:\phalix\dashboard ; git pull
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup_wallet_disb_task.ps1

param(
  [string]$Branch     = "mamora",
  [string]$RepoPath   = "C:\phalix\dashboard",
  [string]$ConfigPath = "C:\phalix\sync_engine.json",
  [int]$Minutes       = 1,
  [string]$TaskName   = "phalix_wallet_disb"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "STOP: open PowerShell as Administrator first."; exit 1 }

$worker = Join-Path $RepoPath "scripts\wallet_disbursement_worker.ps1"
if (-not (Test-Path $worker))     { Write-Host "STOP: worker not found: $worker  (did you git pull?)"; exit 1 }
if (-not (Test-Path $ConfigPath)) { Write-Host "STOP: config not found: $ConfigPath"; exit 1 }

Write-Host "== dry-run self-check (no write) ==" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $worker -Branch $Branch -ConfigPath $ConfigPath
if ($LASTEXITCODE -ne 0) { Write-Host ("STOP: dry-run failed (exit {0}). Fix config/connectivity before scheduling." -f $LASTEXITCODE); exit 1 }
Write-Host "dry-run OK." -ForegroundColor Green

# launcher
$log = "C:\phalix\wallet_disb.log"
$launcher = "C:\phalix\run_wallet_disb.cmd"
$cmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$worker`" -Branch $Branch -ConfigPath `"$ConfigPath`" -Apply >> `"$log`" 2>&1`r`n"
[IO.File]::WriteAllText($launcher, $cmd, [Text.Encoding]::ASCII)
Write-Host "launcher written: $launcher"

# scheduled task every N minutes
& schtasks /create /tn $TaskName /tr "`"$launcher`"" /sc minute /mo $Minutes /f | Out-Null
Write-Host ("scheduled task '{0}' created (every {1} min)." -f $TaskName, $Minutes) -ForegroundColor Green
& schtasks /query /tn $TaskName /fo LIST | Select-String "TaskName|Status|Next Run|Schedule"
Write-Host ""
Write-Host ("log: $log   (watch it with:  Get-Content `"$log`" -Tail 20 -Wait )")
