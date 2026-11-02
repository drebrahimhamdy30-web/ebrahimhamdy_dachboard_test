# setup_credits_task.ps1 - daily scheduled sync for customer credits. Run ONCE,
# as Administrator, on MASTER.  ASCII-only on purpose (PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI and mangles Arabic, breaking the parse).
#
#   schedules:  Phalix_Customer_Credits  - every day at 03:00
#
# It needs no secrets of its own: the sync script reads the four branch
# connections and the Supabase service key from C:\phalix\sync_engine.json,
# which already exists for the other syncs.  The task runs as SYSTEM so there
# is no stored Windows password; eplus is reached with SQL logins, which work
# fine for SYSTEM.
#
# Why 03:00: the pharmacy still issues bills past 22:00, so a nightly run
# after midnight sees a complete day.  The sync re-reads the whole history
# anyway (a customer can collect his medicine two years later), so the exact
# hour only decides how fresh the screen is, never what it can see.
param(
  [string]$RepoDir  = "C:\phalix\dashboard",
  [string]$TaskName = "Phalix_Customer_Credits",
  [string]$At       = "03:00",
  [switch]$Remove
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { L "stop: open PowerShell as Administrator." 'Red'; exit 1 }

if ($Remove) {
  & schtasks /delete /tn $TaskName /f | Out-Null
  L "removed: $TaskName" 'Yellow'; exit 0
}

$script = Join-Path $RepoDir "scripts\sync_customer_credits.ps1"
if (-not (Test-Path $script)) { L "stop: not found - $script  (git pull in $RepoDir first)" 'Red'; exit 1 }
if (-not (Test-Path "C:\phalix\sync_engine.json")) { L "stop: C:\phalix\sync_engine.json is missing" 'Red'; exit 1 }

# run it once now, read-only, so a broken setup fails here and not at 03:00
L "checking the sync can run (read-only)..." 'Cyan'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -WhatIf
if ($LASTEXITCODE -ne 0) { L "stop: the dry run failed - fix that before scheduling." 'Red'; exit 1 }

$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
& schtasks /create /tn $TaskName /tr $cmd /sc daily /st $At /ru SYSTEM /rl HIGHEST /f | Out-Null
L "created: $TaskName - every day at $At (as SYSTEM)" 'Green'

L ""
L "run it now:        schtasks /run /tn $TaskName"
L "check last result: schtasks /query /tn $TaskName /v /fo LIST"
L "log:               C:\phalix\sync_customer_credits.log"
L "remove it:         .\scripts\setup_credits_task.ps1 -Remove"
