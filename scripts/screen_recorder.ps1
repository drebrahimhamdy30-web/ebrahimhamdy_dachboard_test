# screen_recorder.ps1 - light, always-on screen recording for cashier PCs
#
# Why: eplus logs tell us WHO did WHAT and WHEN (deleted bills, price changes,
# safe moves) but not what was on the screen. A low-fps recording, stamped with
# the real time and the PC name, lets us jump straight to the minute of any
# flagged event instead of watching hours of video.
#
# Design:
#   - ffmpeg gdigrab, 1 frame/sec by default, scaled to 720p, H.264 ultrafast:
#     ~1-2 GB/day per PC and very low CPU, OK for old cashier machines.
#   - Every frame carries "PCNAME  YYYY-MM-DD HH:MM:SS" burned in (bottom-left).
#   - 10-minute files named PCNAME_YYYYMMDD_HHMMSS.mkv (plays in VLC) so a timestamp maps to a file.
#   - Runs in the USER session (scheduled task at logon). It must NOT run as
#     SYSTEM: session 0 has no desktop, gdigrab would record a black screen.
#   - ffmpeg is restarted every hour (also recovers from crashes), and files
#     older than -KeepDays are deleted on each restart.
#   - Single instance via a named mutex.
#
# ASCII-only on purpose: a .ps1 with Arabic and no BOM is read as ANSI by
# PowerShell 5.1 and breaks with misleading errors.
#
# Usage:
#   .\screen_recorder.ps1 -Minutes 2            # foreground test, 2 minutes
#   .\screen_recorder.ps1                        # run forever (what the task runs)
#   .\screen_recorder.ps1 -Install               # task at logon, hidden window
#   .\screen_recorder.ps1 -Uninstall

param(
  [string]$OutDir         = "D:\phalix_rec",
  [int]   $Fps            = 1,
  [int]   $Height         = 720,
  [int]   $SegmentMinutes = 10,
  [int]   $KeepDays       = 30,
  [int]   $Minutes        = 0,       # >0 = stop after N minutes (testing)
  [string]$Ffmpeg         = "",
  [switch]$Install,
  [switch]$Uninstall
)
$ErrorActionPreference = "Continue"
$TaskName = "Phalix - screen recorder"
$Pc = $env:COMPUTERNAME

if ($Uninstall) {
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; "task removed" } catch { "no task named '$TaskName'" }
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -like "*gdigrab*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "stopped ffmpeg $($_.ProcessId)" }
  return
}

if ($Install) {
  $self = $MyInvocation.MyCommand.Path
  $arg  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -OutDir `"$OutDir`" -Fps $Fps -Height $Height -SegmentMinutes $SegmentMinutes -KeepDays $KeepDays"
  $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
  $t = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
  $p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  "installed + started: '$TaskName' for $env:USERNAME  ->  $OutDir"
  return
}

# ---- single instance ----
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\PhalixScreenRecorder", [ref]$created)
if (-not $created) { "another recorder is already running - exit"; return }

# ---- locate ffmpeg ----
if (-not $Ffmpeg) {
  $c = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($c) { $Ffmpeg = $c.Source }
  else {
    $cand = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) { $Ffmpeg = $cand.FullName }
  }
}
if (-not $Ffmpeg -or -not (Test-Path $Ffmpeg)) { "STOP: ffmpeg.exe not found (install it or pass -Ffmpeg <path>)"; return }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$log = Join-Path $OutDir "recorder.log"
function Log($m) { $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m; Add-Content -Path $log -Value $line; Write-Host $line }

# timestamp + PC name burned into every frame. Kept in a file so the drawtext
# escaping never goes through PowerShell quoting.
$font = "C\:/Windows/Fonts/arial.ttf"
$filter = "scale=-2:$Height,drawtext=fontfile='$font':text='$Pc  %{localtime\:%Y-%m-%d %H\\\:%M\\\:%S}':x=10:y=h-th-10:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=6"
$filterFile = Join-Path $OutDir "filter.txt"
[IO.File]::WriteAllText($filterFile, $filter)

$deadline = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { [datetime]::MaxValue }
Log "start  pc=$Pc fps=$Fps height=$Height seg=${SegmentMinutes}m keep=${KeepDays}d ffmpeg=$Ffmpeg"

try {
  while ((Get-Date) -lt $deadline) {
    # retention
    $old = Get-ChildItem $OutDir -Filter "*.mkv" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) }
    if ($old) { $old | Remove-Item -Force -ErrorAction SilentlyContinue; Log ("retention: deleted {0} file(s)" -f @($old).Count) }

    $runSec = [int][Math]::Min(3600, [Math]::Max(5, ($deadline - (Get-Date)).TotalSeconds))
    $pattern = Join-Path $OutDir ("{0}_%Y%m%d_%H%M%S.mkv" -f $Pc)
    $ffArgs = @(
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "gdigrab", "-framerate", "$Fps", "-draw_mouse", "1", "-i", "desktop",
      "-t", "$runSec",
      "-/filter:v", $filterFile,   # ffmpeg >= 7.1: "-/opt file" reads the value from a file (-filter_script is gone in 9.x)
      "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-crf", "30", "-pix_fmt", "yuv420p",
      # write every frame to disk right away: ffmpeg otherwise buffers ~256 KB in
      # memory, and a power cut / kill lost everything past that (tested: 10s of 40)
      "-flush_packets", "1",
      "-g", "$([Math]::Max(1, $Fps * 10))",
      # Matroska: written as a continuous stream, so a hard power-off/kill keeps
      # everything up to the last seconds. (Plain mp4 writes its index at the end
      # = a killed file is unreadable; fragmented mp4 lost ~30s of 40 in testing.)
      "-segment_format", "matroska",
      "-segment_format_options", "flush_packets=1:cluster_time_limit=1000",   # 1s clusters, flushed
      "-f", "segment", "-segment_time", "$($SegmentMinutes * 60)", "-reset_timestamps", "1", "-strftime", "1",
      $pattern
    )
    $p = Start-Process -FilePath $Ffmpeg -ArgumentList $ffArgs -NoNewWindow -PassThru -RedirectStandardError (Join-Path $OutDir "ffmpeg_err.txt")
    $null = $p.Handle   # PS 5.1 quirk: without touching Handle, ExitCode stays null after exit
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
      $err = (Get-Content (Join-Path $OutDir "ffmpeg_err.txt") -ErrorAction SilentlyContinue | Select-Object -Last 3) -join " | "
      Log "ffmpeg exit $($p.ExitCode): $err"
      Start-Sleep -Seconds 10   # don't spin if the screen is locked or ffmpeg keeps failing
    }
  }
} finally {
  Log "stop"
  $mutex.ReleaseMutex()
}
