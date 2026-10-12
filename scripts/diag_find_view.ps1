# diag_find_view.ps1 — pinpoint the type-5 ("other") account table. Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
function Show($title,$sql,[int]$maxrows=60){
  Write-Host "`n===== $title =====" -ForegroundColor Cyan
  try{
    $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60
    $r=$c.ExecuteReader(); $n=0
    while($r.Read() -and $n -lt $maxrows){
      $n++; $parts=@()
      for($i=0;$i -lt $r.FieldCount;$i++){ $v= if($r.IsDBNull($i)){'<null>'}else{$r.GetValue($i)}; $parts+=("{0}={1}" -f $r.GetName($i),$v) }
      Write-Host ("  " + ($parts -join " | "))
    }
    if($n -eq 0){ Write-Host "  (none)" -ForegroundColor DarkYellow }
    $r.Close()
  }catch{ Write-Host ("  err: {0}" -f $_.Exception.Message) -ForegroundColor Red }
}
# remaining base tables (from 'mon' onward) + any with expense/paper/account-ish names
Show "tables L..Z" "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_NAME > 'mon' ORDER BY TABLE_NAME" 300
# F_Papers structure + sample
Show "F_Papers columns" "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='F_Papers'"
Show "F_Papers top5" "SELECT TOP 5 * FROM F_Papers"
# does F_Account_Chart use ac_code 65/85/89 for these names?
Show "F_Account_Chart ac_code in (65,85,89)" "SELECT ac_id, ac_code, ac_name_ar FROM F_Account_Chart WHERE ac_code IN ('65','85','89')"
Show "F_Account_Chart ac_id in (3,5,60,65,85,89)" "SELECT ac_id, ac_code, ac_name_ar FROM F_Account_Chart WHERE ac_id IN (3,5,60,65,85,89) ORDER BY ac_id"
$cn.Close(); Write-Host "`ndone."
