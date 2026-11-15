<#  probe_region_source.ps1 - منين الفرع بيجيب المنطقة؟

    الليه: ربط المنطقة (Customer_Delivery.cd_region_id -> Delivery_cost_region)
    شغال على المعمورة (حل 50 من 65) لكنه فشل على سان ستيفانو (حل 3 من 18)،
    بينما الـAPI بيحلها هناك صح («جليم» «لوران» «باكوس» «فليمنج ترام»).
    يبقى مصدر المنطقة على الفرع ده مختلف، ولازم نعرفه قبل ما نكتب.

    بيفحص لنفس الفواتير المعلقة: cd_region_id و cust_region_id و
    cust_dc_region_id، وعدد صفوف Customer_Delivery للعميل، وبيجرب
    الثلاث مسارات ويقول أنهي واحد بيحل أكتر.

    قراءة فقط.
#>
param([ValidateSet("mamora","san","bishr","seyouf")][string]$Branch = "san")
$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 70); Write-Host "  $t"; Write-Host ("=" * 70) }

$cfg = Get-Content "C:\phalix\sync_engine.json" -Raw | ConvertFrom-Json
$b = $cfg.branches.$Branch
if (-not $b) { Write-Host "مفيش اعدادات للفرع $Branch"; return }
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

Head "1) نسبة الحل في كل مسار (على الطلبات المعلقة)"
$r = Q @"
SELECT
  COUNT(*) AS الاجمالي,
  SUM(CASE WHEN cd.cd_region_id > 0 THEN 1 ELSE 0 END)        AS [عبر Customer_Delivery],
  SUM(CASE WHEN c.cust_region_id > 0 THEN 1 ELSE 0 END)       AS [عبر cust_region_id],
  SUM(CASE WHEN c.cust_dc_region_id > 0 THEN 1 ELSE 0 END)    AS [عبر cust_dc_region_id]
FROM sales_trans_h h
LEFT JOIN Customer c ON c.cust_id = h.cust_id
LEFT JOIN Customer_Delivery cd ON cd.cd_cust_id = h.cust_id
     AND cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id)
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
"@
if ($r.Count) { $r[0].PSObject.Properties | ForEach-Object { "    {0,-26} = {1}" -f $_.Name, $_.Value } }

Head "2) كام عنوان لكل عميل؟ (لو اكتر من واحد، اختيارنا ممكن يكون غلط)"
$r = Q @"
SELECT TOP 6 h.sth_id, h.cust_id,
  (SELECT COUNT(*) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id) AS عدد_العناوين,
  (SELECT COUNT(*) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id AND x.cd_region_id > 0) AS منها_بمنطقة,
  c.cust_region_id, c.cust_dc_region_id
FROM sales_trans_h h LEFT JOIN Customer c ON c.cust_id = h.cust_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P' ORDER BY h.sth_id DESC
"@
$r | Format-Table -AutoSize | Out-String | Write-Host

Head "3) جدول المناطق - كام صف وعينة"
$r = Q "SELECT COUNT(*) AS n FROM Delivery_cost_region"
"    Delivery_cost_region: $(if($r.Count){$r[0].n}else{'?'}) صف"
$r = Q "SELECT TOP 5 dc_id, dc_region_name_ar FROM Delivery_cost_region ORDER BY dc_id"
$r | Format-Table -AutoSize | Out-String | Write-Host
Head "4) ليه الاسم مش بيتلاقى؟ - cd_region_id مقابل Delivery_cost_region"
$r = Q @"
SELECT TOP 12
  h.sth_id,
  cd.cd_region_id,
  CASE WHEN dcr.dc_id IS NULL THEN 'مش موجود في جدول المناطق' ELSE dcr.dc_region_name_ar END AS النتيجة
FROM sales_trans_h h
LEFT JOIN Customer_Delivery cd ON cd.cd_cust_id = h.cust_id
     AND cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id)
LEFT JOIN Delivery_cost_region dcr ON dcr.dc_id = cd.cd_region_id
WHERE h.sth_delivery = 1 AND h.sth_flag = 'P'
ORDER BY h.sth_id DESC
"@
$r | Format-Table -AutoSize | Out-String | Write-Host

Head "5) مدى ارقام المناطق"
$r = Q @"
SELECT 'المستخدمة في العناوين' AS المصدر, MIN(cd_region_id) AS الاقل, MAX(cd_region_id) AS الاكبر, COUNT(DISTINCT cd_region_id) AS عدد_مختلف
FROM Customer_Delivery WHERE cd_region_id > 0
UNION ALL
SELECT 'الموجودة في جدول المناطق', MIN(dc_id), MAX(dc_id), COUNT(*) FROM Delivery_cost_region
"@
$r | Format-Table -AutoSize | Out-String | Write-Host

Head "6) كام عنوان رقم منطقته مش في الجدول"
$r = Q @"
SELECT
  COUNT(*) AS [عناوين بمنطقة],
  SUM(CASE WHEN dcr.dc_id IS NULL THEN 1 ELSE 0 END) AS [رقمها مش في الجدول]
FROM Customer_Delivery cd
LEFT JOIN Delivery_cost_region dcr ON dcr.dc_id = cd.cd_region_id
WHERE cd.cd_region_id > 0
"@
if ($r.Count) { $r[0].PSObject.Properties | ForEach-Object { "    {0,-26} = {1}" -f $_.Name, $_.Value } }