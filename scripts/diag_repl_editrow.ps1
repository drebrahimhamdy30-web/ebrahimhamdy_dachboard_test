# diag_repl_editrow.ps1 — READ-ONLY. يطبع كل أعمدة صفوف «Edit Customer» بالظبط
# (القالب اللى هنقلّده) + هل trans_id IDENTITY + الحد الأقصى الحالى.
# التشغيل: .\scripts\diag_repl_editrow.ps1 -Password (ConvertTo-SecureString '...' -AsPlainText -Force)

param([System.Security.SecureString]$Password, [string]$User="phalix_reader")
$ErrorActionPreference="Stop"; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8
function L($m){ Write-Host $m }
if(-not $Password){ $Password = Read-Host "باسوورد $User" -AsSecureString }
$pw=[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if([string]::IsNullOrWhiteSpace($pw)){ L "وقّف: فاضى."; exit 1 }
$cn=New-Object System.Data.SqlClient.SqlConnection("Server=localhost,1433;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=15"); $cn.Open()
function Rows($sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=120; $r=$c.ExecuteReader()
  $cols=@(); for($i=0;$i -lt $r.FieldCount;$i++){ $cols+=$r.GetName($i) }
  $n=0; while($r.Read()){ $n++; L ("─── صف $n ───"); for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); L ("   {0} = {1}" -f $cols[$i], $(if($v -is [DBNull]){'<null>'}else{$v})) } ; L "" }
  if($n -eq 0){ L "  (لا شىء)" }; $r.Close()
}

L "== trans_id IDENTITY؟ + الحد الأقصى =="
Rows "SELECT COLUMNPROPERTY(OBJECT_ID('Replication_Trans'),'trans_id','IsIdentity') AS is_identity, IDENT_CURRENT('Replication_Trans') AS ident_current, MAX(trans_id) AS max_id FROM Replication_Trans"

L ""; L "== أحدث 3 صفوف Edit Customer (كل الأعمدة) =="
Rows "SELECT TOP 3 * FROM Replication_Trans WHERE general_name='Edit Customer' ORDER BY trans_id DESC"

$cn.Close(); L "خلص. ابعت كل المخرجات."
