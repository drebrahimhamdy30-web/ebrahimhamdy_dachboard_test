# diag_notes_pair.ps1 — raw eplus fh_notes for the 12:43 sarf pair (read-only)
#   powershell -ExecutionPolicy Bypass -File scripts\diag_notes_pair.ps1
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15")
$cn.Open()
$c = $cn.CreateCommand()
$c.CommandText = "SELECT fh_id, fh_code, fh_value, fh_from_id, fh_to_type, fh_to_id, fh_actual_date, DATALENGTH(fh_notes) AS notes_bytes, fh_notes FROM F_Transaction_Header WHERE fh_id IN (1580696,1580697) ORDER BY fh_id"
$r = $c.ExecuteReader()
while($r.Read()){
  for($i=0;$i -lt $r.FieldCount;$i++){
    $v = if($r.IsDBNull($i)){'<null>'}else{$r.GetValue($i)}
    Write-Host ("  {0,-16} = {1}" -f $r.GetName($i), $v)
  }
  Write-Host "  ----"
}
$r.Close()
# also: is there any row whose fh_notes contains water, around this shift?
$c2 = $cn.CreateCommand()
$w = [string]([char]0x0645 + [char]0x064A + [char]0x0627 + [char]0x0647)
$c2.CommandText = "SELECT fh_id, fh_value, fh_to_id, fh_notes FROM F_Transaction_Header WHERE fh_notes LIKE @q AND fh_id BETWEEN 1580600 AND 1580800"
$p = $c2.Parameters.Add("@q",[System.Data.SqlDbType]::NVarChar,100); $p.Value = "%$w%"
$r2 = $c2.ExecuteReader()
Write-Host "`n  rows with water-note in this shift range:"
while($r2.Read()){ Write-Host ("    fh_id={0} value={1} to_id={2} notes={3}" -f $r2.GetValue(0),$r2.GetValue(1),$r2.GetValue(2),$r2.GetValue(3)) }
$r2.Close()
$cn.Close()
Write-Host "`ndone."
