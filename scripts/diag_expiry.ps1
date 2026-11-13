param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json", [string]$Branch="mamora")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.$Branch
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
$c=$cn.CreateCommand()
$c.CommandText=@"
SELECT ic.itm_id, SUM(cl.itm_qty) qty, CONVERT(varchar(10), MIN(cl.itm_expiry_date), 120) nearest_exp
FROM Item_Class cl JOIN Item_Catalog ic ON ic.itm_id = cl.itm_id
WHERE ic.com_id = 1228 AND cl.active_flg = 'A' AND cl.itm_qty > 0
  AND cl.itm_expiry_date >= GETDATE() AND cl.itm_expiry_date < DATEADD(month, 4, GETDATE())
GROUP BY ic.itm_id ORDER BY nearest_exp
"@
$c.CommandTimeout=90; $r=$c.ExecuteReader()
$n=0; while($r.Read()){ $n++; Write-Host ("  itm_id={0} | qty={1} | exp={2}" -f $r.GetValue(0),$r.GetValue(1),$r.GetValue(2)) }
Write-Host ("COUNT amtnan expiring <4mo mamora: " + $n)
$r.Close(); $cn.Close()
