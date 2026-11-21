# diag_lamifen_5801.ps1 — READ-ONLY.
# السؤال: «لاميفين كريم» كود 5801 ظهر في «أصناف غير مطلوبة» على فاتورة
# فارما اوفر سيز 1020472635 بتاريخ 19/11/2026 بكمية 25 — والمالك مش
# لاقيها في فواتير الشراء على eplus. نتأكد من المصدر مباشرة.
#
# الشك الأساسي: الكود 5801 عندنا بيرجع برقمين داخليين مختلفين
# (itm_id 35235 و 53987) — و itm_code مش فريد في eplus، فممكن
# الاسم المعروض جاي من صنف تاني بنفس الكود.
#
# التشغيل من الماستر:  .\scripts\diag_lamifen_5801.ps1

param(
  [System.Security.SecureString]$Password,
  [string]$User = "phalix_reader"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m){ Write-Host $m }

if (-not $Password) {
  $cfgPath = Join-Path $env:USERPROFILE ".phalix\eplus_master.json"
  if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ForEach-Object { $_ -replace "^﻿","" } | ConvertFrom-Json
    $plain = $cfg.password; if (-not $plain) { $plain = $cfg.pw }
    if ($plain) { $Password = ConvertTo-SecureString $plain -AsPlainText -Force }
    if ($cfg.user) { $User = $cfg.user }
  }
}
if (-not $Password) { $Password = Read-Host "باسوورد $User" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if ([string]::IsNullOrWhiteSpace($pw)) { L "وقّف: الباسوورد فاضى."; exit 1 }

function Open($h){
  $c = New-Object System.Data.SqlClient.SqlConnection("Server=$h;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=10")
  $c.Open(); return $c
}
function Rows($cn,$sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $r=$c.ExecuteReader()
  $cols=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $cols+=$r.GetName($i) }
  $n=0
  while($r.Read()){
    $line=@(); for($i=0;$i -lt $r.FieldCount;$i++){
      $v=$r.GetValue($i); $line += ("{0}={1}" -f $cols[$i], $(if($v -is [DBNull]){'<null>'}else{$v}))
    }
    L ("    " + ($line -join "  |  ")); $n++
  }
  if($n -eq 0){ L "    (لا شىء)" }
  $r.Close()
}

$cn = Open "localhost,1433"   # المعمورة = الماستر

L "══ ١) كل الأصناف اللى كودها 5801 فى الكتالوج ══"
Rows $cn @"
SELECT itm_id, itm_code, itm_name_ar, itm_ismedicine, itm_sell_price, itm_active
  FROM Item WHERE LTRIM(RTRIM(itm_code)) = '5801'
"@

L ""
L "══ ٢) الفاتورة 1020472635 من فارما اوفر سيز — موجودة فى eplus؟ ══"
Rows $cn @"
SELECT h.pth_id, h.ven_bill_no, h.ven_bill_date, h.sec_insert_date,
       v.ven_name_ar, h.total_bill, h.bill_status, h.sto_id
  FROM pur_trans_h h LEFT JOIN Vendor v ON v.ven_id = h.ven_id
 WHERE h.ven_bill_no = '1020472635'
"@

L ""
L "══ ٣) بنود pth_id = 64701 (الفاتورة اللى عندنا) ══"
Rows $cn @"
SELECT d.ptd_id, d.itm_id, i.itm_code, i.itm_name_ar,
       d.qty, d.itm_pur_price, d.exp_date, d.ptd_batch
  FROM pur_trans_d d LEFT JOIN Item i ON i.itm_id = d.itm_id
 WHERE d.pth_id = 64701
 ORDER BY d.ptd_id
"@

L ""
L "══ ٤) أى شراء للصنفين (35235 / 53987) آخر ٤٠ يوم ══"
Rows $cn @"
SELECT h.pth_id, h.ven_bill_no, h.ven_bill_date, v.ven_name_ar,
       d.itm_id, i.itm_code, i.itm_name_ar, d.qty, d.itm_pur_price
  FROM pur_trans_d d
  JOIN pur_trans_h h ON h.pth_id = d.pth_id
  LEFT JOIN Vendor v ON v.ven_id = h.ven_id
  LEFT JOIN Item i   ON i.itm_id = d.itm_id
 WHERE d.itm_id IN (35235, 53987)
   AND h.ven_bill_date >= DATEADD(day, -40, GETDATE())
 ORDER BY h.ven_bill_date DESC
"@

$cn.Close()
L ""
L "تم."
