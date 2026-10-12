# dump_other_expenses.ps1 — emit Other_Expenses as compact JSON {oe_id:name} for mamora. Read-only.
param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
$cn.Open()
$c = $cn.CreateCommand(); $c.CommandText = "SELECT oe_id, oe_name_ar FROM Other_Expenses ORDER BY oe_id"
$r = $c.ExecuteReader()
$m = @{}
while($r.Read()){ $m["$([int]$r.GetValue(0))"] = ($r.GetValue(1)).ToString().Trim() }
$r.Close(); $cn.Close()
$m | ConvertTo-Json -Compress | Out-File -FilePath "$env:USERPROFILE\.phalix\other_expenses_mamora.json" -Encoding utf8
Write-Host ("rows: {0} -> saved" -f $m.Count)
