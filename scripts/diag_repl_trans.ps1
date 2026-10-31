# diag_repl_trans.ps1 — READ-ONLY. يكشف شكل جدول Replication_Trans (صندوق مزامنة
# التطبيق) + عيّنة صفوف حديثة + أى صف خاص بـCustomer_Delivery، عشان نقلّد الكتابة.
# التشغيل من الماستر: .\scripts\diag_repl_trans.ps1 -Password (ConvertTo-SecureString '...' -AsPlainText -Force)

param([System.Security.SecureString]$Password, [string]$User="phalix_reader")
$ErrorActionPreference="Stop"; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8
function L($m){ Write-Host $m }
if(-not $Password){ $Password = Read-Host "باسوورد $User" -AsSecureString }
$pw=[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if([string]::IsNullOrWhiteSpace($pw)){ L "وقّف: الباسوورد فاضى."; exit 1 }
$cn=New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=15"); $cn.Open()
function Rows($sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $r=$c.ExecuteReader()
  $cols=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $cols+=$r.GetName($i) }
  $n=0; while($r.Read()){ $line=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); $s=$(if($v -is [DBNull]){'<null>'}else{[string]$v}); if($s.Length -gt 90){$s=$s.Substring(0,90)+'…'}; $line+=("{0}={1}" -f $cols[$i],$s) }; L ("  "+($line -join " | ")); $n++ }
  if($n -eq 0){ L "  (لا شىء)" }; L "  ($n صف)"; $r.Close()
}

L "== أعمدة Replication_Trans =="
Rows "SELECT c.colid,c.name AS col,t.name AS type,c.length FROM syscolumns c JOIN systypes t ON c.xusertype=t.xusertype WHERE c.id=OBJECT_ID('Replication_Trans') ORDER BY c.colid"

L ""; L "== عدد الصفوف =="
Rows "SELECT COUNT(*) AS cnt FROM Replication_Trans"

L ""; L "== أحدث 15 صف (كل الأعمدة) =="
Rows "SELECT TOP 15 * FROM Replication_Trans ORDER BY 1 DESC"

# لو فيه عمود نصّى بيحمل اسم الجدول/الجملة، نحاول نلاقى صفوف Customer_Delivery
L ""; L "== صفوف تخص Customer_Delivery (بحث فى الأعمدة النصّية) =="
$txtCols = @()
$c=$cn.CreateCommand(); $c.CommandText="SELECT c.name FROM syscolumns c JOIN systypes t ON c.xusertype=t.xusertype WHERE c.id=OBJECT_ID('Replication_Trans') AND t.name IN ('varchar','nvarchar','char','nchar','text','ntext')"
$r=$c.ExecuteReader(); while($r.Read()){ $txtCols+=[string]$r['name'] }; $r.Close()
if($txtCols.Count){
  $where = ($txtCols | ForEach-Object { "$_ LIKE '%Customer_Delivery%' OR $_ LIKE '%cd_region%'" }) -join " OR "
  try { Rows "SELECT TOP 10 * FROM Replication_Trans WHERE $where ORDER BY 1 DESC" } catch { L ("  (تعذّر البحث: "+$_.Exception.Message+")") }
} else { L "  (مفيش أعمدة نصّية)" }

$cn.Close(); L ""; L "خلص. ابعت كل المخرجات."
