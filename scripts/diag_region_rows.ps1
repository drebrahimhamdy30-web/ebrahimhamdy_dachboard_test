<#  diag_region_rows.ps1 - المنطقة من العنوان اللي اتباع بيه

    الليه (توجيه المالك): العميل ممكن يكون له اكتر من عنوان، والبائع
    بيختار عنوان معين وقت البيع - فالمنطقة لازم تيجي من **العنوان
    المختار** مش من اول عنوان في قايمة العميل.

    وده يفسر ليه 15 طلب طلعوا بلا منطقة رغم ان العميل عنده منطقة:
    كنت بجيب عنوان تاني غير اللي اتباع بيه.

    العنوان المختار متخزن في sales_deliv_info.address مع الفاتورة.
    السكربت بيجرب يربط بيه ويقارن النتيجة بالطريقة الحالية.

    قراءة فقط.
#>
param([ValidateSet("mamora","san","bishr","seyouf")][string]$Branch = "san")
$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 70); Write-Host "  $t"; Write-Host ("=" * 70) }

$cfg = Get-Content "C:\phalix\sync_engine.json" -Raw | ConvertFrom-Json
$b = $cfg.branches.$Branch
$cs = "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15"
Write-Host "الفرع: $Branch   السيرفر: $($b.server)"

function Q($sql) {
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  try {
    $c.Open(); $cmd=$c.CreateCommand(); $cmd.CommandText=$sql; $cmd.CommandTimeout=40
    $rd=$cmd.ExecuteReader(); $cols=@(); for($i=0;$i -lt $rd.FieldCount;$i++){ $cols+=$rd.GetName($i) }
    $rows=@(); while($rd.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $rd.FieldCount;$i++){ $v=$rd.GetValue($i); $o[$cols[$i]]=$(if($v -is [DBNull]){$null}else{$v}) }; $rows+=[pscustomobject]$o }
    $rd.Close(); return ,$rows
  } catch { Write-Host "  خطأ: $($_.Exception.Message)"; return ,@() }
  finally { $c.Close() }
}

Head "1) كل اعمدة sales_deliv_info - فيه رقم عنوان او منطقة؟"
$r = Q "SELECT c.name, t.name AS typ FROM syscolumns c JOIN systypes t ON t.xtype=c.xtype WHERE c.id=OBJECT_ID('sales_deliv_info') ORDER BY c.colid"
$r | ForEach-Object { "    {0,-22} {1}" -f $_.name, $_.typ }

Head "2) مقارنة الطريقتين على الطلبات المعلقة"
$r = Q @"
SELECT
  COUNT(*) AS الاجمالي,
  SUM(CASE WHEN old_r.dc_region_name_ar IS NOT NULL THEN 1 ELSE 0 END) AS [الطريقة الحالية],
  SUM(CASE WHEN new_r.dc_region_name_ar IS NOT NULL THEN 1 ELSE 0 END) AS [بالعنوان المختار]
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d ON d.sth_id = h.sth_id
LEFT JOIN Customer_Delivery old_cd ON old_cd.cd_cust_id = h.cust_id
     AND old_cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x
                          WHERE x.cd_cust_id = h.cust_id AND x.cd_region_id > 0)
LEFT JOIN Delivery_cost_region old_r ON old_r.dc_id = old_cd.cd_region_id
LEFT JOIN Customer_Delivery new_cd ON new_cd.cd_cust_id = h.cust_id
     AND RTRIM(LTRIM(new_cd.cd_address)) = RTRIM(LTRIM(d.address))
LEFT JOIN Delivery_cost_region new_r ON new_r.dc_id = new_cd.cd_region_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
"@
if ($r.Count) { $r[0].PSObject.Properties | ForEach-Object { "    {0,-22} = {1}" -f $_.Name, $_.Value } }

Head "3) عينة - العنوان المختار مقابل عناوين العميل"
$r = Q @"
SELECT TOP 8
  h.sth_id, h.cust_id,
  LEFT(RTRIM(LTRIM(d.address)),34)        AS العنوان_المختار,
  new_cd.cd_id                            AS طابق_عنوان,
  new_r.dc_region_name_ar                 AS منطقة_بالعنوان,
  old_r.dc_region_name_ar                 AS منطقة_بالطريقة_القديمة
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d ON d.sth_id = h.sth_id
LEFT JOIN Customer_Delivery old_cd ON old_cd.cd_cust_id = h.cust_id
     AND old_cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x
                          WHERE x.cd_cust_id = h.cust_id AND x.cd_region_id > 0)
LEFT JOIN Delivery_cost_region old_r ON old_r.dc_id = old_cd.cd_region_id
LEFT JOIN Customer_Delivery new_cd ON new_cd.cd_cust_id = h.cust_id
     AND RTRIM(LTRIM(new_cd.cd_address)) = RTRIM(LTRIM(d.address))
LEFT JOIN Delivery_cost_region new_r ON new_r.dc_id = new_cd.cd_region_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
ORDER BY h.sth_id DESC
"@
$r | Format-Table -AutoSize | Out-String | Write-Host