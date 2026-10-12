# diag_other_expenses.ps1 — confirm Other_Expenses is the type-5 table. Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
function Show($title,$sql,[int]$maxrows=80){
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
Show "Other_Expenses columns" "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Other_Expenses' ORDER BY ORDINAL_POSITION"
Show "Other_Expenses for ids 3,5,60,65,85,89" "SELECT * FROM Other_Expenses WHERE oe_id IN (3,5,60,65,85,89) ORDER BY oe_id"
Show "Other_Expenses all (first 80)" "SELECT * FROM Other_Expenses ORDER BY oe_id"
$cn.Close(); Write-Host "`ndone."
