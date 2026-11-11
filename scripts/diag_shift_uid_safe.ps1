# diag_shift_uid_safe.ps1 - is sec_insert_uid always numeric? A non-numeric value
# would make CAST(... AS int) blow up the whole sync query. Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open(); $c=$cn.CreateCommand(); $c.CommandTimeout=120
$c.CommandText = @"
SELECT COUNT(*) AS total,
  SUM(CASE WHEN sc.sec_insert_uid IS NULL THEN 1 ELSE 0 END) AS is_null,
  SUM(CASE WHEN ISNUMERIC(LTRIM(RTRIM(sc.sec_insert_uid))) = 0 THEN 1 ELSE 0 END) AS not_numeric,
  SUM(CASE WHEN e.e_id IS NULL THEN 1 ELSE 0 END) AS no_employee_match
FROM Shift_Changes sc
LEFT JOIN Employee e ON e.e_id = CASE WHEN ISNUMERIC(LTRIM(RTRIM(sc.sec_insert_uid)))=1
                                      THEN CAST(LTRIM(RTRIM(sc.sec_insert_uid)) AS decimal(18,0)) END
"@
$r=$c.ExecuteReader(); $r.Read()
Write-Host ""
Write-Host ("total              : {0}" -f $r.GetValue(0))
Write-Host ("sec_insert_uid NULL: {0}" -f $r.GetValue(1))
Write-Host ("not numeric        : {0}" -f $r.GetValue(2))
Write-Host ("no Employee match  : {0}" -f $r.GetValue(3))
$r.Close(); $cn.Close(); Write-Host "`ndone."
