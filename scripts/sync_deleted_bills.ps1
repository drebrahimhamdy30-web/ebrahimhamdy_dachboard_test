# Sync deleted sale bills (sales_trans_h_del) from each branch Genius DB to Supabase.
# ASCII-only source on purpose (no Arabic literals) so PowerShell 5.1 ANSI reads it safely;
# Arabic values come from the DB at runtime and are \u-escaped by ConvertTo-Json.
# Reads branch creds + Supabase service key from sync_engine.json (NOT in the repo).
# On the master: -ConfigPath C:\phalix\sync_engine.json runs all branches.
param(
  [string]$ConfigPath = "C:\phalix\sync_engine.json",
  [int]$Days = 14
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$SB  = $cfg.supabaseUrl.TrimEnd('/')
$KEY = $cfg.serviceKey
$hdr = @{ apikey = $KEY; Authorization = "Bearer $KEY"; 'Content-Type' = 'application/json'; Prefer = 'resolution=merge-duplicates,return=minimal' }

$sql = @"
SELECT h.sth_id,
       st.sto_name_ar AS store_name,
       cu.cust_name_ar AS cust_name_ar,
       CASE WHEN sv.svi_id IS NOT NULL THEN 'visa' ELSE 'cash' END AS bill_type,
       h.no_of_items,
       h.total_bill_after_disc AS total_after_disc,
       h.total_dis_per AS disc_perc,
       h.total_des_mon AS disc_value,
       CONVERT(varchar, h.sec_insert_date, 120) AS create_bill_date,
       ce.e_Name AS created_by,
       de.e_Name AS deleted_by,
       CONVERT(varchar, h.sth_delTime, 120) AS delete_bill_date,
       h.sth_del_pc_name AS device_name
FROM sales_trans_h_del h
LEFT JOIN Store st           ON st.sto_id  = h.sto_id
LEFT JOIN Customer cu        ON cu.cust_id = h.cust_id
LEFT JOIN Employee ce        ON ce.e_id    = h.sec_insert_uid
LEFT JOIN Employee de        ON de.e_id    = h.sec_update_uid
LEFT JOIN sales_visa_info sv ON sv.sth_id  = h.sth_id
WHERE h.sth_delTime >= DATEADD(day, -$Days, GETDATE())
"@

function N($v) { if ($v -eq $null -or $v -is [System.DBNull]) { return $null } return $v }

foreach ($bname in $cfg.branches.PSObject.Properties.Name) {
  $b = $cfg.branches.$bname
  try {
    $cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=25")
    $cn.Open()
    $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 120
    $r = $c.ExecuteReader()
    $rows = New-Object System.Collections.ArrayList
    while ($r.Read()) {
      [void]$rows.Add([ordered]@{
          branch           = $bname
          bill_no          = [string]$r['sth_id']
          store_name       = N $r['store_name']
          cust_name_ar     = N $r['cust_name_ar']
          bill_type        = N $r['bill_type']
          no_of_items      = N $r['no_of_items']
          total_after_disc = N $r['total_after_disc']
          disc_perc        = N $r['disc_perc']
          disc_value       = N $r['disc_value']
          create_bill_date = N $r['create_bill_date']
          created_by       = N $r['created_by']
          deleted_by       = N $r['deleted_by']
          delete_bill_date = N $r['delete_bill_date']
          device_name      = N $r['device_name']
          delete_type      = 'full'
        })
    }
    $r.Close(); $cn.Close()
    $total = 0
    for ($i = 0; $i -lt $rows.Count; $i += 500) {
      $end = [Math]::Min($i + 499, $rows.Count - 1)
      $chunk = @($rows[$i..$end])
      $json = $chunk | ConvertTo-Json -Depth 5
      if ($chunk.Count -eq 1) { $json = "[$json]" }
      $body = [System.Text.Encoding]::UTF8.GetBytes($json)
      Invoke-RestMethod -Method Post -Uri "$SB/rest/v1/deleted_sales_bills?on_conflict=branch,bill_no" -Headers $hdr -Body $body | Out-Null
      $total += $chunk.Count
    }
    Write-Host "$bname : $total deleted bills synced"
  }
  catch {
    Write-Host "$bname : ERROR $($_.Exception.Message)"
  }
}
