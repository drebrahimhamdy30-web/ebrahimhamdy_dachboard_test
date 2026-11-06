# eplus_monthly_pnl.ps1
# صافى المبيعات ومجمل الربح لكل فرع ولكل شهر — زى شاشة «إجماليات» فى eplus.
# **قراءة فقط** — مابيعدّلش أى حاجة.
#
# المعادلة اتطابقت بالقرش مع شاشة «إجماليات» (المعمورة أكتوبر 2026):
#   بعد الخصم   = Σ كمية×سعر×(1-خصم الصنف%)×(1-خصم الفاتورة%) − الخصم المبلغ
#   صافى المرتجع = نفس المعادلة على الكمية المرتجعة، بتاريخ المرتجع (تاريخ تعديل السطر)
#   صافى المبيعات = بعد الخصم − صافى المرتجع
#   مجمل الربح   = صافى المبيعات − (تكلفة المباع − تكلفة المرتجع)
# بيطلع العمودين: «بالإقفال» (تاريخ التوصيل، زى ✓ حسب تاريخ الإقفال)
# و«بالإدخال» (من غير العلامة).
#
# التشغيل على الماستر:
#   cd C:\phalix\dashboard ; git pull ; .\scripts\eplus_monthly_pnl.ps1
#   .\scripts\eplus_monthly_pnl.ps1 -From 2026-01-01 -To 2026-11-01

param(
  [string]$ConfigPath = "",
  [string]$From = "2026-01-01",
  [string]$To   = "2026-11-01",
  [int]$StoreId = 1
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$candidates = @(@(
  $ConfigPath,
  "C:\phalix\sync_engine.json",
  "C:\ProgramData\phalix\sync_engine.json",
  "$env:USERPROFILE\.phalix\sync_engine.json"
) | Where-Object { $_ -and (Test-Path $_) })
if (-not $candidates) { Write-Host "مش لاقي ملف إعدادات المزامنة."; exit 1 }
$cfg = Get-Content $candidates[0] -Raw | ConvertFrom-Json
Write-Host "الإعدادات: $($candidates[0])   الفترة: $From → $To   المخزن: $StoreId`n"

# basis: c = بالإقفال (تاريخ التوصيل)، i = بالإدخال
$SQL = @"
SELECT x.basis, x.ym, SUM(x.aft) aft, SUM(x.cost) cost, SUM(x.rnet) rnet, SUM(x.rcost) rcost
FROM (
  SELECT b.basis, CONVERT(char(7), CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END, 120) ym,
    SUM(d.qnty*d.itm_sell*(1-ISNULL(d.itm_dis_per,0)/100.0)*(1-ISNULL(h.total_dis_per,0)/100.0)) aft,
    SUM(d.qnty*d.itm_cost) cost, 0 rnet, 0 rcost
  FROM (SELECT 'c' basis UNION ALL SELECT 'i') b
  CROSS JOIN sales_trans_h h WITH (NOLOCK) JOIN sales_trans_d d WITH (NOLOCK) ON d.sth_id=h.sth_id
  WHERE h.sto_id=@sto
    AND CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END >= @f
    AND CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END <  @t
  GROUP BY b.basis, CONVERT(char(7), CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END, 120)
  UNION ALL
  SELECT b.basis, CONVERT(char(7), CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END, 120),
    -SUM(ISNULL(h.total_des_mon,0)), 0, 0, 0
  FROM (SELECT 'c' basis UNION ALL SELECT 'i') b CROSS JOIN sales_trans_h h WITH (NOLOCK)
  WHERE h.sto_id=@sto
    AND CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END >= @f
    AND CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END <  @t
  GROUP BY b.basis, CONVERT(char(7), CASE b.basis WHEN 'c' THEN ISNULL(h.delivery_date,h.sec_insert_date) ELSE h.sec_insert_date END, 120)
  UNION ALL
  SELECT b.basis, CONVERT(char(7), d.sec_update_date, 120), 0, 0,
    SUM(d.itm_back*d.itm_sell*(1-ISNULL(d.itm_dis_per,0)/100.0)*(1-ISNULL(h.total_dis_per,0)/100.0)),
    SUM(d.itm_back*d.itm_cost)
  FROM (SELECT 'c' basis UNION ALL SELECT 'i') b
  CROSS JOIN sales_trans_h h WITH (NOLOCK) JOIN sales_trans_d d WITH (NOLOCK) ON d.sth_id=h.sth_id
  WHERE h.sto_id=@sto AND d.itm_back>0 AND d.sec_update_date>=@f AND d.sec_update_date<@t
  GROUP BY b.basis, CONVERT(char(7), d.sec_update_date, 120)
) x
GROUP BY x.basis, x.ym
"@

$fmt = "{0,-8} {1,-8} {2,16} {3,14} {4,16} {5,14}"
foreach ($p in $cfg.branches.PSObject.Properties) {
  $name = $p.Name; $b = $p.Value
  Write-Host ("=== {0}  ({1})" -f $name, $b.server)
  $cs = "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15"
  try { $cn = New-Object System.Data.SqlClient.SqlConnection($cs); $cn.Open() }
  catch { Write-Host ("   ✗ مفيش وصول: {0}`n" -f $_.Exception.Message); continue }
  try {
    $c = $cn.CreateCommand(); $c.CommandText = $SQL; $c.CommandTimeout = 900
    [void]$c.Parameters.AddWithValue("@sto", $StoreId)
    [void]$c.Parameters.AddWithValue("@f", [datetime]$From)
    [void]$c.Parameters.AddWithValue("@t", [datetime]$To)
    $r = $c.ExecuteReader(); $rows = @{}
    while ($r.Read()) {
      $k = "$($r['ym'])"; if (-not $rows[$k]) { $rows[$k] = @{} }
      $net  = [double]$r['aft'] - [double]$r['rnet']
      $prof = $net - ([double]$r['cost'] - [double]$r['rcost'])
      $rows[$k][$r['basis']] = @($net, $prof)
    }
    $r.Close()
    Write-Host ($fmt -f "الفرع","الشهر","صافى م.(إقفال)","ربح (إقفال)","صافى م.(إدخال)","ربح (إدخال)")
    foreach ($k in ($rows.Keys | Sort-Object)) {
      $cc = $rows[$k]['c']; $ii = $rows[$k]['i']
      Write-Host ($fmt -f $name, $k, ('{0:N2}' -f $cc[0]), ('{0:N2}' -f $cc[1]), ('{0:N2}' -f $ii[0]), ('{0:N2}' -f $ii[1]))
    }
  } catch { Write-Host ("   ✗ خطأ: {0}" -f $_.Exception.Message) }
  finally { $cn.Close() }
  Write-Host ""
}
Write-Host "خلص."
