<#  probe_branch_sql.ps1 - هل نقدر نقرا الطلبات المعلقة من سيرفرات الفروع؟

    الليه: المزامنة المباشرة اشتغلت على المعمورة (localhost = الماستر) وبقت
    تجيب الطلبات في 0.1 ثانية بدل 30-90 من الـAPI. المالك طلب تعميمها على
    سان ستيفانو وسيدي بشر (السيوف مؤجل).

    كل فرع عنده قاعدة Genius منفصلة على سيرفره. وحسابات SQL بتشتغل عن بُعد،
    بس الحساب لازم يكون اتعمل محليًا على سيرفره - فمش مضمون إن phalix_reader
    موجود على الفروع زي ما هو على الماستر.

    السكربت بيفحص: إعدادات الاتصال في sync_engine.json، والوصول لكل سيرفر،
    وعدد الطلبات المعلقة بفلتر sth_flag='P'، وعينة صف للتأكد إن الأعمدة
    نفسها. من غير أي كتابة.
#>
$ErrorActionPreference = "Continue"
function Head($t){ Write-Host ""; Write-Host ("=" * 70); Write-Host "  $t"; Write-Host ("=" * 70) }

$cfgPath = "C:\phalix\sync_engine.json"
if (-not (Test-Path $cfgPath)) { Write-Host "مالقيتش $cfgPath"; return }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

Head "1) شكل اعدادات الفروع (من غير اسرار)"
if (-not $cfg.branches) { Write-Host "  مفيش مفتاح branches" }
else {
  $cfg.branches.PSObject.Properties | ForEach-Object {
    $b = $_.Value
    $fields = $b.PSObject.Properties | ForEach-Object {
      if ($_.Name -match 'pass|pwd|secret|key') { "$($_.Name)=***" } else { "$($_.Name)=$($_.Value)" }
    }
    "    {0,-10} : {1}" -f $_.Name, ($fields -join "  ")
  }
}

Head "2) اختبار الاتصال وعد الطلبات المعلقة"
# كل فرع له حساب وكلمة سر خاصة به في sync_engine.json - استخدام كلمة سر
# الماستر لباقي الفروع بيرجع "Login failed" (اتجرب 2026-11-15).
$targets = @()
foreach ($k in @("mamora","san","bishr")) {
  $b = $cfg.branches.$k
  if (-not $b) { Write-Host "  مفيش اعدادات للفرع $k"; continue }
  $targets += @{ name = $k; server = $b.server; user = $b.user; pass = $b.password }
}

foreach ($t in $targets) {
  Write-Host ""
  Write-Host "  ---- $($t.name)  [$($t.server)]  user=$($t.user) ----"
  $cs = "Server=$($t.server);Database=Genius;User ID=$($t.user);Password=$($t.pass);Connect Timeout=10"
  $c = New-Object System.Data.SqlClient.SqlConnection $cs
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $c.Open()
    $cmd = $c.CreateCommand(); $cmd.CommandTimeout = 30
    $cmd.CommandText = "SELECT COUNT(*) FROM sales_trans_h WHERE sth_delivery=1 AND sth_flag='P'"
    $n = $cmd.ExecuteScalar()
    $sw.Stop()
    "    اتصال ناجح - طلبات معلقة: {0}   في {1:N2} ثانية" -f $n, $sw.Elapsed.TotalSeconds
    if ($n -gt 1000) { "    تحذير: الرقم كبير جدا - الفلتر ممكن يكون مختلف على الفرع ده" }

    $cmd2 = $c.CreateCommand(); $cmd2.CommandTimeout = 30
    $cmd2.CommandText = @"
SELECT TOP 1 h.sth_id, h.temp_col4 AS cust_name, h.no_of_items, h.total_bill_net,
       d.tel, dcr.dc_region_name_ar AS region, emp.e_Name AS employee
FROM sales_trans_h h
LEFT JOIN sales_deliv_info d ON d.sth_id = h.sth_id
LEFT JOIN Customer_Delivery cd ON cd.cd_cust_id = h.cust_id
     AND cd.cd_id = (SELECT MIN(x.cd_id) FROM Customer_Delivery x WHERE x.cd_cust_id = h.cust_id)
LEFT JOIN Delivery_cost_region dcr ON dcr.dc_id = cd.cd_region_id
LEFT JOIN Employee emp ON emp.e_id = h.emp_id
WHERE h.sth_delivery=1 AND h.sth_flag='P' ORDER BY h.sth_id DESC
"@
    $rd = $cmd2.ExecuteReader()
    if ($rd.Read()) {
      for ($i=0; $i -lt $rd.FieldCount; $i++) {
        $v = $rd.GetValue($i); if ($v -is [DBNull]) { $v = "(فاضي)" }
        "      {0,-14} = {1}" -f $rd.GetName($i), $v
      }
    } else { "      مفيش صفوف" }
    $rd.Close()
  } catch {
    $sw.Stop()
    "    فشل بعد {0:N2}ث: {1}" -f $sw.Elapsed.TotalSeconds, ($_.Exception.Message -replace "\s+"," ")
  } finally { $c.Close() }
}

Head "الخلاصة"
Write-Host "  لو الفرعين اتصلوا ورجعوا عدد معقول (عشرات مش آلاف) وعينة سليمة،"
Write-Host "  نقدر نعمم المزامنة عليهم بنفس السكربت بـ-Server و-BranchId."
Write-Host "  لو فشل الاتصال، يبقى phalix_reader مش موجود على سيرفر الفرع"
Write-Host "  ولازم يتعمل محليًا هناك الاول."