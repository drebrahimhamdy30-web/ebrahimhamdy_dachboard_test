# update_contract_percent.ps1
# يعدّل نسبة خصم عقد التعاقد (أبوقير) من 10% لـ15% على حصة الشركة.
#
# ── الفكرة ───────────────────────────────────────────────────────
# الشركة بتخصم نسبة من **نصيبها هي**، مش من إجمالي الفاتورة. فالرقم
# المخزّن في eplus = النسبة × حصة الشركة. اتأكد ده على تلات عقود:
#     العميل يدفع 25% → الشركة 75% → 10% × 75% = 7.50  ✓
#     العميل يدفع  0% → الشركة 100% → 10% × 100% = 10.00 ✓
#     العميل يدفع 50% → الشركة 50% → 10% × 50% =  5.00  ✓
#
# ── ليه بنحسب مش بنضرب ×1.5 ──────────────────────────────────────
# القيمة الجديدة = النسبة_الجديدة × (100 − cc_pay_perc) ÷ 100
# الحساب ده **ذاتي التصحيح**: لو السكربت اتشغّل مرتين بالغلط النتيجة
# واحدة. الضرب في 1.5 كان هيطلّع 16.875% في المرة التانية — غلط صامت
# في فلوس كل فاتورة.
#
# ⚠️ كل فرع له قاعدة Genius خاصة على سيرفره. العقد **متكرر** مش
#    مشترك — اتأكد إن الفروع التلاتة بتطبّق 7.5% حاليًا. يعني
#    السكربت لازم يتشغّل على **كل سيرفر فرع**.
#
# التشغيل:
#   .\update_contract_percent.ps1                    ← عرض بس (آمن)
#   .\update_contract_percent.ps1 -Apply             ← تنفيذ

param(
  [string]$Server     = "localhost,1433",
  [string]$User       = "phalix_writer",
  [string]$Password   = "",
  [decimal]$NewPerc   = 15,      # النسبة الجديدة على حصة الشركة
  [int]$OwnerCustId   = 359,     # العميل المالك للعقود (ابو قير معتمد)
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$log = Join-Path $PSScriptRoot "update_contract_percent.log"
function L($m){ $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
                Add-Content -Path $log -Value $line -Encoding UTF8; Write-Host $line }

if (-not $Password) { L "وقّف: مرّر -Password باسورد phalix_writer."; exit 1 }

$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Genius;User ID=$User;Password=$Password;Connect Timeout=20")
try { $cn.Open(); L "متصل بـ$Server كـ$User" } catch { L "فشل الاتصال: $($_.Exception.Message)"; exit 1 }

$COLS = @('cc_local_items_disc','cc_imported_items_disc','cc_local_made_items_disc',
          'cc_special_import_items_disc','cc_investment_items_disc','cc_other_items_disc')

function Report($title){
  L ""
  L "== $title =="
  $c = $cn.CreateCommand()
  $c.CommandText = @"
SELECT cc_id, cc_name, cc_pay_perc,
       $($COLS -join ', '),
       (SELECT COUNT(*) FROM Customer cu WHERE cu.cust_contract_id = cc.cc_id) AS عملاء
  FROM Customer_Contracts cc
 WHERE cc_cust_id = $OwnerCustId AND cc_active = 1
 ORDER BY cc_id
"@
  $r = $c.ExecuteReader()
  while($r.Read()){
    $share = 100 - [decimal]$r['cc_pay_perc']
    $cur   = [decimal]$r['cc_local_items_disc']
    # النسبة الفعلية على حصة الشركة = المخزّن ÷ الحصة × 100
    $eff   = if($share -gt 0){ [math]::Round($cur / $share * 100, 2) } else { 0 }
    L ("  عقد {0,-3} {1,-18} العميل يدفع {2,5}%  الشركة {3,5}%  المخزّن {4,6}  = {5,5}% على حصتها  ({6} عميل)" -f `
        $r['cc_id'], $r['cc_name'], $r['cc_pay_perc'], $share, $cur, $eff, $r['عملاء'])
  }
  $r.Close()
}

Report "قبل"

# القيمة الجديدة لكل عقد = NewPerc × حصة الشركة ÷ 100
$setSql = ($COLS | ForEach-Object { "$_ = ($NewPerc * (100 - cc_pay_perc) / 100)" }) -join ",`n       "
$where  = "cc_cust_id = $OwnerCustId AND cc_active = 1 AND cc_pay_perc < 100"

if (-not $Apply) {
  L ""
  L "عرض فقط — مفيش أي تعديل اتعمل."
  L "لو الأرقام فوق صح، شغّل تاني بـ -Apply"
  $cn.Close(); exit 0
}

L ""
L "بطبّق $NewPerc% على حصة الشركة..."
$tx = $cn.BeginTransaction()
try {
  $c = $cn.CreateCommand(); $c.Transaction = $tx
  $c.CommandText = "UPDATE Customer_Contracts SET $setSql, sec_update_date = GETDATE() WHERE $where"
  $n = $c.ExecuteNonQuery()
  L "اتعدّل $n عقد"
  if ($n -lt 1) { throw "مفيش ولا عقد اتعدّل — الشرط غالبًا غلط، بنرجّع." }
  $tx.Commit()
  L "تم الحفظ ✓"
} catch {
  $tx.Rollback()
  L "فشل واترجع كله: $($_.Exception.Message)"
  $cn.Close(); exit 1
}

Report "بعد"
L ""
L "الخطوة الأخيرة: اعمل فاتورة تعاقد تجريبية بصنف واحد وتأكد إن"
L "itm_dis_per في sales_trans_d طلع بالنسبة الجديدة. لو ما اتغيّرش،"
L "الكاشير غالبًا مكاشّش النسبة — اقفله وافتحه."
$cn.Close()
