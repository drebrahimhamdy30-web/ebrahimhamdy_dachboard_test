# diag_find_exp_table.ps1 — locate the type-5 ("other"/expense) accounts table
# Searches for the distinctive expense name "tabadolat" (id 85) across all string
# columns, and dumps the full matching row so we learn the table + id/name columns.
# Read-only. Pure ASCII (term built from Unicode code points).
#   powershell -ExecutionPolicy Bypass -File scripts\diag_find_exp_table.ps1
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# "tabadolat" = Teh Beh Alef Dal Lam Alef Teh
$Q = [string]([char]0x062A+[char]0x0628+[char]0x0627+[char]0x062F+[char]0x0644+[char]0x0627+[char]0x062A)

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15")
$cn.Open()

$cols = @()
$c = $cn.CreateCommand()
$c.CommandText = "SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE DATA_TYPE IN ('nvarchar','nchar','varchar','char','text','ntext') ORDER BY TABLE_NAME"
$r = $c.ExecuteReader()
while($r.Read()){ $cols += [pscustomobject]@{ t=$r.GetString(0); col=$r.GetString(1) } }
$r.Close()
Write-Host ("string columns: {0}" -f $cols.Count) -ForegroundColor Cyan

foreach($x in $cols){
  try{
    $q = $cn.CreateCommand()
    $q.CommandText = "SELECT TOP 2 * FROM [$($x.t)] WHERE [$($x.col)] LIKE @q"
    $p = $q.Parameters.Add("@q",[System.Data.SqlDbType]::NVarChar,200); $p.Value = "%$Q%"
    $q.CommandTimeout = 25
    $rr = $q.ExecuteReader()
    while($rr.Read()){
      Write-Host "`n>>> FOUND in [$($x.t)] (matched col [$($x.col)]):" -ForegroundColor Green
      for($i=0;$i -lt $rr.FieldCount;$i++){
        $v = if($rr.IsDBNull($i)){'<null>'}else{$rr.GetValue($i)}
        Write-Host ("      {0,-22} = {1}" -f $rr.GetName($i), $v)
      }
    }
    $rr.Close()
  }catch{ }
}
$cn.Close()
Write-Host "`ndone."
