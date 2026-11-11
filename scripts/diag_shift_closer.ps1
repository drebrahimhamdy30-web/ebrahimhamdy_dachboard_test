# diag_shift_closer.ps1 - which column in Shift_Changes identifies the employee
# who CLOSED the shift. Read-only. ASCII only (Arabic in a BOM-less .ps1 breaks).
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
function Cols($t){ Write-Host "`n== cols $t ==" -ForegroundColor Cyan
  $c=$cn.CreateCommand(); $c.CommandText="SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$t' ORDER BY ORDINAL_POSITION"
  $r=$c.ExecuteReader(); while($r.Read()){ Write-Host ("  {0} : {1}" -f $r.GetString(0),$r.GetString(1)) }; $r.Close() }
function Show($title,$sql){ Write-Host "`n===== $title =====" -ForegroundColor Cyan
  try{ $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60; $r=$c.ExecuteReader()
    while($r.Read()){ $p=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $v=if($r.IsDBNull($i)){'<null>'}else{$r.GetValue($i)}; $p+=("{0}={1}" -f $r.GetName($i),$v) }
      Write-Host ("  "+($p -join " | ")) }
    $r.Close() }catch{ Write-Host ("  err: {0}" -f $_.Exception.Message) -ForegroundColor Red } }

Cols "Shift_Changes"
Show "Shift_Changes - newest 5 rows (all columns)" "SELECT TOP 5 * FROM Shift_Changes ORDER BY sc_id DESC"
Cols "Employee"
$cn.Close(); Write-Host "`ndone."
