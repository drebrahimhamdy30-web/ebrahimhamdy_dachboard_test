<#  diag_region_rows.ps1 - ليه 15 طلب بلا منطقة؟ صف بصف

    الليه: بعد تبسيط الربط، الرقم فضل 15 بلا منطقة في الفرعين - وده
    بيناقض الفحص المباشر اللي حلّ 18 من 19 على سان ستيفانو وعرض 12 فاتورة
    كلها بمناطق صحيحة. يعني فيه فرق تاني بين الاستعلامين مش الربط.

    السكربت بيشغل **نفس** استعلام المزامنة بالظبط وبيطبع لكل طلب:
    cust_id، العنوان المختار، رقم المنطقة، والاسم الناتج - عشان نشوف
    بالظبط انهي صفوف بتفشل وليه، بدل التخمين.

    قراءة فقط.
#>
param([ValidateSet("mamora","san","bishr","seyouf")][string]$Branch = "san")
$ErrorActionPreference = "Continue"
$cfg = Get-Content "C:\phalix\sync_engine.json" -Raw | ConvertFrom-Json
$b = $cfg.branches.$Branch
$cs = "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15"
Write-Host "الفرع: $Branch   السيرفر: $($b.server)"

$sql = @"
SELECT
  h.sth_id,
  h.cust_id,
  (SELECT COUNT(*) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id) AS عناوين,
  (SELECT COUNT(*) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id AND x.cd_region_id > 0) AS بمنطقة,
  cd.cd_id          AS العنوان_المختار,
  cd.cd_region_id   AS رقم_المنطقة,
  dcr.dc_region_name_ar AS الاسم
FROM sales_trans_h h
LEFT JOIN Customer_Delivery cd
       ON cd.cd_cust_id = h.cust_id
      AND cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x
                       WHERE x.cd_cust_id = h.cust_id AND x.cd_region_id > 0)
LEFT JOIN Delivery_cost_region dcr ON dcr.dc_id = cd.cd_region_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
ORDER BY h.sth_id DESC
"@

$c = New-Object System.Data.SqlClient.SqlConnection $cs
try {
  $c.Open(); $cmd=$c.CreateCommand(); $cmd.CommandText=$sql; $cmd.CommandTimeout=40
  $rd=$cmd.ExecuteReader()
  $rows=@()
  while($rd.Read()){
    $o=[ordered]@{}
    for($i=0;$i -lt $rd.FieldCount;$i++){ $v=$rd.GetValue($i); $o[$rd.GetName($i)] = $(if($v -is [DBNull]){$null}else{$v}) }
    $rows += [pscustomobject]$o
  }
  $rd.Close()
} catch { Write-Host "خطأ: $($_.Exception.Message)"; return } finally { $c.Close() }

Write-Host ""
Write-Host ("إجمالي الصفوف: {0}" -f $rows.Count)
$ok   = @($rows | Where-Object { $_.الاسم })
$fail = @($rows | Where-Object { -not $_.الاسم })
Write-Host ("بمنطقة: {0}    بلا منطقة: {1}" -f $ok.Count, $fail.Count)

Write-Host ""
Write-Host "--- الصفوف اللي فشلت ---"
$fail | Select-Object -First 20 | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "--- عينة ناجحة ---"
$ok | Select-Object -First 3 | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "--- تجميع سبب الفشل ---"
$a = @($fail | Where-Object { $_.عناوين -eq 0 }).Count
$bq= @($fail | Where-Object { $_.عناوين -gt 0 -and $_.بمنطقة -eq 0 }).Count
$cq= @($fail | Where-Object { $_.بمنطقة -gt 0 -and -not $_.رقم_المنطقة }).Count
$d = @($fail | Where-Object { $_.رقم_المنطقة -and -not $_.الاسم }).Count
"  مفيش عنوان للعميل خالص        : $a"
"  عنده عناوين بس مفيش منطقة      : $bq"
"  عنده منطقة بس الربط مالقاش العنوان : $cq"
"  رقم منطقة موجود بس مش في الجدول : $d"