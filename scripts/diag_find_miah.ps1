# diag_find_miah.ps1 — find the eplus table that holds the type-5 ("other") party
# Read-only. The Arabic search term is built from Unicode code points so this
# file stays pure ASCII (PowerShell 5.1 mangles non-BOM UTF-8 Arabic in code).
#   powershell -ExecutionPolicy Bypass -File scripts\diag_find_miah.ps1

param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# target "mya" (Meem Yeh Alef) + control "tklf" (Teh Kaf Lam Feh, from "cost of sales")
$TERMS = @{
  "TARGET_mya"  = [string]([char]0x0645 + [char]0x064A + [char]0x0627)
  "CONTROL_tklf"= [string]([char]0x062A + [char]0x0643 + [char]0x0644 + [char]0x0641)
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15")
$cn.Open()

# all arabic-name columns (ending in _ar)
$cols = @()
$c = $cn.CreateCommand()
$c.CommandText = "SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE DATA_TYPE IN ('nvarchar','nchar','varchar','char','text','ntext') ORDER BY TABLE_NAME"
$r = $c.ExecuteReader()
while($r.Read()){ $cols += [pscustomobject]@{ t=$r.GetString(0); col=$r.GetString(1) } }
$r.Close()
Write-Host ("arabic-name columns scanned: {0}" -f $cols.Count) -ForegroundColor Cyan

foreach($term in $TERMS.GetEnumerator()){
  $hits = 0
  Write-Host "`n===== tables containing [$($term.Key)] =====" -ForegroundColor Cyan
  foreach($x in $cols){
    try{
      $q = $cn.CreateCommand()
      $q.CommandText = "SELECT TOP 2 * FROM [$($x.t)] WHERE [$($x.col)] LIKE @q"
      $p = $q.Parameters.Add("@q",[System.Data.SqlDbType]::NVarChar,200); $p.Value = "%$($term.Value)%"
      $q.CommandTimeout = 20
      $rr = $q.ExecuteReader()
      while($rr.Read()){
        $hits++
        $line = "  [$($x.t)].[$($x.col)] -> "
        for($i=0; $i -lt $rr.FieldCount; $i++){
          $nm = $rr.GetName($i)
          if($nm -match 'id$|^id|code|_ar$' -or $nm -eq $x.col){
            $v = if($rr.IsDBNull($i)){'<null>'}else{$rr.GetValue($i)}
            $line += "$nm=$v; "
          }
        }
        Write-Host $line -ForegroundColor Green
      }
      $rr.Close()
    }catch{ }
  }
  Write-Host ("  total hits: {0}" -f $hits) -ForegroundColor Yellow
}
$cn.Close()
Write-Host "`ndone." -ForegroundColor Green
