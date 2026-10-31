# diag_repl_custedit.ps1 — READ-ONLY. يطبع trans_qry الكامل لأحدث تعديلات عميل
# (form Add_edit_customer_ar) عشان نشوف إزاى التطبيق بيكتب عنوان/منطقة التوصيل
# فى Replication_Trans ونقلّده. العلامة * = بديل ' عند التطبيق.
# اختياري: -Cust <code> لعميل محدّد (لو عدّلته من التطبيق).
# التشغيل: .\scripts\diag_repl_custedit.ps1 -Password (ConvertTo-SecureString '...' -AsPlainText -Force)

param([System.Security.SecureString]$Password, [string]$User="phalix_reader", [string]$Cust)
$ErrorActionPreference="Stop"; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8
function L($m){ Write-Host $m }
if(-not $Password){ $Password = Read-Host "باسوورد $User" -AsSecureString }
$pw=[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if([string]::IsNullOrWhiteSpace($pw)){ L "وقّف: فاضى."; exit 1 }
$cn=New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=15"); $cn.Open()

function Dump($sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=180; $r=$c.ExecuteReader()
  $n=0
  while($r.Read()){
    $n++
    L ("─── trans_id=$($r['trans_id'])  typ=$($r['trans_typ_1'])/$($r['trans_typ_2'])  general_id=$($r['general_id'])  general_name=$($r['general_name'])  uid=$($r['sec_insert_uid'])  $($r['sec_insert_date']) ───")
    $q = if($r['trans_qry'] -is [DBNull]){'<null>'}else{[string]$r['trans_qry']}
    L ("   QRY: " + $q)
    L ""
  }
  if($n -eq 0){ L "  (لا شىء)" }
  $r.Close()
}

if($Cust){
  L "== كل صفوف Replication_Trans للعميل $Cust (general_id) =="
  Dump "SELECT TOP 30 trans_id,trans_typ_1,trans_typ_2,general_id,general_name,sec_insert_uid,sec_insert_date,trans_qry FROM Replication_Trans WHERE general_id=$Cust ORDER BY trans_id DESC"
} else {
  L "== أحدث 8 تعديلات عميل (Add_edit_customer_ar) — trans_qry كامل =="
  Dump "SELECT TOP 8 trans_id,trans_typ_1,trans_typ_2,general_id,general_name,sec_insert_uid,sec_insert_date,trans_qry FROM Replication_Trans WHERE form_nm='Add_edit_customer_ar' ORDER BY trans_id DESC"
}

$cn.Close(); L "خلص. ابعت كل المخرجات."
