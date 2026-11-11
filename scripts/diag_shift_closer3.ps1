# diag_shift_closer3.ps1 - when sc_to_employee <> sec_insert_uid, which one closed?
# Test: the employee a shift is handed TO should be the one who closes the NEXT
# shift on the same cashier point. Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
function Show($title,$sql){ Write-Host "`n===== $title =====" -ForegroundColor Cyan
  try{ $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=90; $r=$c.ExecuteReader()
    while($r.Read()){ $p=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $v=if($r.IsDBNull($i)){'<null>'}else{$r.GetValue($i)}; $p+=("{0}={1}" -f $r.GetName($i),$v) }
      Write-Host ("  "+($p -join " | ")) }
    $r.Close() }catch{ Write-Host ("  err: {0}" -f $_.Exception.Message) -ForegroundColor Red } }

Show "A) recent rows where they DIFFER - both names" @"
SELECT TOP 10 sc.sc_id, sc.sc_cashier_id AS point, sc.sec_insert_date AS closed_at,
       sc.sec_insert_uid AS uid, eu.e_Name AS uid_name,
       CAST(CAST(sc.sc_to_employee AS int) AS varchar) AS to_emp, et.e_Name AS to_name
FROM Shift_Changes sc
LEFT JOIN Employee eu ON CAST(eu.e_id AS int) = CAST(LTRIM(RTRIM(sc.sec_insert_uid)) AS int)
LEFT JOIN Employee et ON et.e_id = sc.sc_to_employee
WHERE LTRIM(RTRIM(sc.sec_insert_uid)) <> CAST(CAST(sc.sc_to_employee AS int) AS varchar)
ORDER BY sc.sc_id DESC
"@

Show "B) chain test: does THIS row's to_emp match the NEXT shift's uid on the same point?" @"
WITH q AS (
  SELECT sc_id, sc_cashier_id,
         LTRIM(RTRIM(sec_insert_uid)) AS uid,
         CAST(CAST(sc_to_employee AS int) AS varchar) AS to_emp,
         LEAD(LTRIM(RTRIM(sec_insert_uid))) OVER (PARTITION BY sc_cashier_id ORDER BY sc_id) AS next_uid
  FROM Shift_Changes
)
SELECT COUNT(*) AS pairs,
       SUM(CASE WHEN to_emp = next_uid THEN 1 ELSE 0 END) AS to_emp_matches_next_closer,
       SUM(CASE WHEN uid    = next_uid THEN 1 ELSE 0 END) AS uid_matches_next_closer
FROM q WHERE next_uid IS NOT NULL AND uid <> to_emp
"@
$cn.Close(); Write-Host "`ndone."
