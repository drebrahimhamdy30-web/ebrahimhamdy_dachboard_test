# diag_shift_closer4.ps1 - chain test in SQL 2000 syntax (no CTE, no LEAD).
# Claim: sc_to_employee = who RECEIVES the shift, so it should equal the
# sec_insert_uid of the NEXT shift closed on the same cashier point.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
$c=$cn.CreateCommand(); $c.CommandTimeout=180
$c.CommandText = @"
SELECT COUNT(*) AS pairs,
  SUM(CASE WHEN LTRIM(RTRIM(nx.sec_insert_uid)) = CAST(CAST(sc.sc_to_employee AS int) AS varchar)
           THEN 1 ELSE 0 END) AS to_emp_is_next_closer,
  SUM(CASE WHEN LTRIM(RTRIM(nx.sec_insert_uid)) = LTRIM(RTRIM(sc.sec_insert_uid))
           THEN 1 ELSE 0 END) AS uid_is_next_closer
FROM Shift_Changes sc
JOIN Shift_Changes nx
  ON nx.sc_cashier_id = sc.sc_cashier_id
 AND nx.sc_id = (SELECT MIN(x.sc_id) FROM Shift_Changes x
                  WHERE x.sc_cashier_id = sc.sc_cashier_id AND x.sc_id > sc.sc_id)
WHERE sc.sec_insert_date >= '2026-01-01'
  AND LTRIM(RTRIM(sc.sec_insert_uid)) <> CAST(CAST(sc.sc_to_employee AS int) AS varchar)
"@
$r=$c.ExecuteReader(); $r.Read()
Write-Host ""
Write-Host ("rows where the two columns differ (2026)       : {0}" -f $r.GetValue(0))
Write-Host ("  sc_to_employee = the NEXT shift's closer     : {0}" -f $r.GetValue(1))
Write-Host ("  sec_insert_uid = the NEXT shift's closer     : {0}" -f $r.GetValue(2))
$r.Close(); $cn.Close(); Write-Host "`ndone."
