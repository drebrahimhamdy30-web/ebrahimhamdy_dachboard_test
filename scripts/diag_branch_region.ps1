# diag_branch_region.ps1 — READ-ONLY. اكتشاف آلية مزامنة المنطقة من التطبيق للفروع.
#  (أ) الماستر: تريجرات Customer_Delivery + نصّها، ريبليكشن ناتيف، جداول نقل/مزامنة
#      محتملة، وأى جدول «ظل» فيه أعمدة شبه Customer_Delivery (outbox).
#  (ب) كل فرع: منطقة العملاء المعدّلين + الوصول.
# التشغيل من الماستر: .\scripts\diag_branch_region.ps1   (باسوورد phalix_reader)

param(
  [System.Security.SecureString]$Password,
  [string]$User = "phalix_reader",
  [string[]]$Codes = @("16713","20685")
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function L($m){ Write-Host $m }
if (-not $Password) { $Password = Read-Host "باسوورد $User" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if ([string]::IsNullOrWhiteSpace($pw)) { L "وقّف: الباسوورد فاضى."; exit 1 }
function Open($h){ $c=New-Object System.Data.SqlClient.SqlConnection("Server=$h;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=8"); $c.Open(); return $c }
function Rows($cn,$sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $r=$c.ExecuteReader()
  $cols=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $cols+=$r.GetName($i) }
  $n=0; while($r.Read()){ $line=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); $line+=("{0}={1}" -f $cols[$i],$(if($v -is [DBNull]){'<null>'}else{$v})) }; L ("    "+($line -join "  |  ")); $n++ }
  if($n -eq 0){ L "    (لا شىء)" }; $r.Close()
}

L "========== (أ) آلية المزامنة على الماستر =========="
try {
  $cn = Open "localhost,1433"

  L ""; L "• تريجرات على Customer_Delivery (+ مفعّلة؟):"
  Rows $cn "SELECT name, OBJECTPROPERTY(id,'ExecIsTriggerDisabled') AS disabled FROM sysobjects WHERE type='TR' AND parent_obj=OBJECT_ID('Customer_Delivery')"

  L ""; L "• نصّ تريجرات Customer_Delivery:"
  Rows $cn "SELECT o.name AS trg, cm.text FROM syscomments cm JOIN sysobjects o ON o.id=cm.id WHERE o.type='TR' AND o.parent_obj=OBJECT_ID('Customer_Delivery') ORDER BY o.name, cm.colid"

  L ""; L "• ريبليكشن ناتيف (مقالات Customer%):"
  Rows $cn "IF OBJECT_ID('sysarticles') IS NOT NULL SELECT name FROM sysarticles WHERE name LIKE '%Customer%' ELSE SELECT 'لا يوجد نشر ناتيف' AS info"

  L ""; L "• جداول نقل/مزامنة محتملة بالاسم:"
  Rows $cn "SELECT name FROM sysobjects WHERE type='U' AND (name LIKE '%transfer%' OR name LIKE '%trans_log%' OR name LIKE '%sync%' OR name LIKE '%repl%' OR name LIKE '%send%' OR name LIKE '%export%' OR name LIKE '%branch%' OR name LIKE '%out%' OR name LIKE '%mirror%' OR name LIKE '%dist%' OR name LIKE '%_log') ORDER BY name"

  L ""; L "• جداول تانية فيها عمود شبه cd_region/cd_cust (outbox ظل محتمل):"
  Rows $cn "SELECT DISTINCT o.name FROM sysobjects o JOIN syscolumns c ON c.id=o.id WHERE o.type='U' AND o.name<>'Customer_Delivery' AND (c.name LIKE 'cd_region%' OR c.name LIKE 'cd_cust%' OR c.name='cd_id') ORDER BY o.name"

  $cn.Close()
} catch { L ("✗ خطأ على الماستر: " + $_.Exception.Message) }

L ""; L "========== (ب) منطقة العملاء على كل فرع =========="
$servers = @(
  @{ n="المعمورة (ماستر)"; h="localhost,1433" },
  @{ n="سيدى بشر";        h="192.168.192.80,1433" },
  @{ n="سان ستيفانو";     h="192.168.192.225,1433" },
  @{ n="السيوف";          h="192.168.192.44,1433" }
)
$codesIn = "'" + ($Codes -join "','") + "'"
foreach($s in $servers){
  L ""; L ("===== " + $s.n + "  (" + $s.h + ") =====")
  try {
    $cn = Open $s.h; L "  ✓ واصل"
    Rows $cn @"
SELECT c.cust_code, cd.cd_id, cd.cd_region_id, dc.dc_region_name_ar AS region, cd.sec_update_uid
  FROM Customer c JOIN Customer_Delivery cd ON cd.cd_cust_id=c.cust_id
  LEFT JOIN Delivery_cost_region dc ON dc.dc_id=cd.cd_region_id
 WHERE c.cust_code IN ($codesIn) ORDER BY c.cust_code, cd.cd_id
"@
    $cn.Close()
  } catch { L ("  ✗ مش واصل/خطأ: " + $_.Exception.Message) }
}
L ""; L "خلص. ابعت كل المخرجات."
