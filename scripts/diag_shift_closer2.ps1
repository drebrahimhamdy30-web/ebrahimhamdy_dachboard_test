# diag_shift_closer2.ps1 - does sc_to_employee always equal sec_insert_uid, across all branches? Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
foreach($bn in @('mamora','san','bishr','seyouf')){
  $b = $cfg.branches.$bn
  if(-not $b){ Write-Host "$bn : no config"; continue }
  try{
    $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
    $cn.Open()
    $c=$cn.CreateCommand(); $c.CommandTimeout=60
    $c.CommandText = @"
SELECT COUNT(*) AS total,
       SUM(CASE WHEN LTRIM(RTRIM(sec_insert_uid)) = CAST(CAST(sc_to_employee AS int) AS varchar) THEN 1 ELSE 0 END) AS same,
       SUM(CASE WHEN sec_insert_uid IS NULL OR LTRIM(RTRIM(sec_insert_uid))='' THEN 1 ELSE 0 END) AS uid_empty,
       SUM(CASE WHEN sc_to_employee IS NULL THEN 1 ELSE 0 END) AS to_empty
FROM Shift_Changes
"@
    $r=$c.ExecuteReader(); $r.Read()
    Write-Host ("{0,-8} total={1,-6} same={2,-6} uid_empty={3,-4} to_empty={4}" -f $bn,$r.GetValue(0),$r.GetValue(1),$r.GetValue(2),$r.GetValue(3))
    $r.Close()
    # names for the ids actually used
    $c2=$cn.CreateCommand(); $c2.CommandTimeout=60
    $c2.CommandText = "SELECT TOP 8 e.e_id, e.e_Name, COUNT(*) n FROM Shift_Changes sc LEFT JOIN Employee e ON e.e_id = sc.sc_to_employee GROUP BY e.e_id, e.e_Name ORDER BY n DESC"
    $r2=$c2.ExecuteReader()
    while($r2.Read()){ $nm = if($r2.IsDBNull(1)){'<no match>'}else{$r2.GetValue(1)}; Write-Host ("    id={0,-6} {1,-28} shifts={2}" -f $r2.GetValue(0),$nm,$r2.GetValue(2)) }
    $r2.Close(); $cn.Close()
  }catch{ Write-Host ("{0,-8} err: {1}" -f $bn, $_.Exception.Message) -ForegroundColor Red }
}
Write-Host "`ndone."
