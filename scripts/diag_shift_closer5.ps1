# diag_shift_closer5.ps1 - today's mamora shifts with BOTH employee names,
# to line up against eplus "Drawer Handover" report columns. Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
$c=$cn.CreateCommand(); $c.CommandTimeout=90
$c.CommandText = @"
SELECT sc.sc_id, sc.sc_cashier_id AS point,
       CONVERT(varchar(20), sc.sec_insert_date, 108) AS closed_time,
       LTRIM(RTRIM(sc.sec_insert_uid)) AS uid, eu.e_Name AS uid_name,
       CAST(CAST(sc.sc_to_employee AS int) AS varchar) AS to_emp, et.e_Name AS to_name,
       sc.sc_start_cash AS opening, sc.sc_curr_cash AS value, sc.sc_act_cash AS actual
FROM Shift_Changes sc
LEFT JOIN Employee eu ON CAST(eu.e_id AS int) = CAST(LTRIM(RTRIM(sc.sec_insert_uid)) AS int)
LEFT JOIN Employee et ON et.e_id = sc.sc_to_employee
WHERE sc.sec_insert_date >= '2026-11-11' AND sc.sec_insert_date < '2026-11-12'
ORDER BY sc.sc_cashier_id, sc.sec_insert_date
"@
$r=$c.ExecuteReader()
Write-Host ""
Write-Host ("{0,-7} {1,-6} {2,-10} {3,-28} {4,-28} {5,10} {6,10}" -f 'sc_id','point','time','sec_insert_uid (MOSTAKHDEM?)','sc_to_employee (MOSTALEM?)','opening','actual')
Write-Host ("-"*110)
while($r.Read()){
  $un = if($r.IsDBNull(4)){'<none>'}else{$r.GetValue(4)}
  $tn = if($r.IsDBNull(6)){'<none>'}else{$r.GetValue(6)}
  Write-Host ("{0,-7} {1,-6} {2,-10} {3,-28} {4,-28} {5,10} {6,10}" -f $r.GetValue(0),$r.GetValue(1),$r.GetValue(2),$un,$tn,$r.GetValue(7),$r.GetValue(9))
}
$r.Close(); $cn.Close(); Write-Host "`ndone."
