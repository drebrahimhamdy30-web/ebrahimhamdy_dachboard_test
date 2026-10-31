# diag_repl_cust.ps1 — READ-ONLY. يدوّر فى Replication_Trans عن طريقة تسجيل تعديل
# العميل/التوصيل (التصنيف + أمثلة) عشان نقلّدها بالظبط.
# التشغيل: .\scripts\diag_repl_cust.ps1 -Password (ConvertTo-SecureString '...' -AsPlainText -Force)

param([System.Security.SecureString]$Password, [string]$User="phalix_reader")
$ErrorActionPreference="Stop"; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8
function L($m){ Write-Host $m }
if(-not $Password){ $Password = Read-Host "باسوورد $User" -AsSecureString }
$pw=[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if([string]::IsNullOrWhiteSpace($pw)){ L "وقّف: فاضى."; exit 1 }
$cn=New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=15"); $cn.Open()
function Rows($sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $r=$c.ExecuteReader()
  $cols=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $cols+=$r.GetName($i) }
  $n=0; while($r.Read()){ $line=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); $s=$(if($v -is [DBNull]){'<null>'}else{[string]$v}); if($s.Length -gt 140){$s=$s.Substring(0,140)+'…'}; $line+=("{0}={1}" -f $cols[$i],$s) }; L ("  "+($line -join " | ")); $n++ }
  if($n -eq 0){ L "  (لا شىء)" }; L "  ($n)"; $r.Close()
}

L "== أكثر form_nm تكرارًا =="
Rows "SELECT TOP 30 form_nm, COUNT(*) AS cnt FROM Replication_Trans GROUP BY form_nm ORDER BY COUNT(*) DESC"

L ""; L "== form_nm فيها Cust/Deliver/Address/عميل/توصيل =="
Rows "SELECT DISTINCT form_nm FROM Replication_Trans WHERE form_nm LIKE '%cust%' OR form_nm LIKE '%deliver%' OR form_nm LIKE '%address%' OR form_nm LIKE '%عميل%' OR form_nm LIKE '%توصيل%' OR form_nm LIKE '%منطق%'"

L ""; L "== general_name فيها Cust/Deliver/Address/عميل/توصيل =="
Rows "SELECT DISTINCT general_name FROM Replication_Trans WHERE general_name LIKE '%cust%' OR general_name LIKE '%deliver%' OR general_name LIKE '%address%' OR general_name LIKE '%عميل%' OR general_name LIKE '%توصيل%' OR general_name LIKE '%منطق%'"

L ""; L "== trans_qry فيها Customer (أمثلة حديثة) =="
Rows "SELECT TOP 10 trans_id, trans_typ_1, trans_typ_2, general_id, general_name, form_nm, trans_qry FROM Replication_Trans WHERE trans_qry LIKE '%Customer%' ORDER BY trans_id DESC"

L ""; L "== trans_qry فيها region/dc_ (أمثلة) =="
Rows "SELECT TOP 10 trans_id, general_id, form_nm, trans_qry FROM Replication_Trans WHERE trans_qry LIKE '%region%' OR trans_qry LIKE '%dc_region%' OR trans_qry LIKE '%Delivery%' ORDER BY trans_id DESC"

$cn.Close(); L ""; L "خلص. ابعت كل المخرجات."
