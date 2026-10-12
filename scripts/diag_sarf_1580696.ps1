# diag_sarf_1580696.ps1 — تشخيص بند الصرف 1580696 (ليه بيظهر «تكلفة المبيعات» بدل «مياه»)
#
# يشتغل على جهاز المعمورة (اللي عليه محرّك المزامنة). قراءة فقط — كله SELECT.
#
#   powershell -ExecutionPolicy Bypass -File scripts\diag_sarf_1580696.ps1
#
# بيطلّع: (أ) كل أعمدة ترويسة المعاملة بقيمها  (ب) سطور التفصيل لو موجودة
#         (ج) الاسم المقابل لـ id=65 في دليل الحسابات  (د) أي جدول فيه «مياه»

param([string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$b = $cfg.branches.mamora
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=15")
$cn.Open()

function RunShow($title, $sql){
  Write-Host "`n===== $title =====" -ForegroundColor Cyan
  try{
    $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 30
    $r = $c.ExecuteReader()
    $n = 0
    while($r.Read()){
      $n++
      Write-Host "--- صف $n ---" -ForegroundColor DarkGray
      for($i=0; $i -lt $r.FieldCount; $i++){
        $name = $r.GetName($i)
        $val  = if($r.IsDBNull($i)){ "<null>" } else { $r.GetValue($i) }
        Write-Host ("  {0,-24} = {1}" -f $name, $val)
      }
    }
    if($n -eq 0){ Write-Host "  (مفيش صفوف)" -ForegroundColor DarkYellow }
    $r.Close()
  }catch{ Write-Host ("  خطأ: {0}" -f $_.Exception.Message) -ForegroundColor Red }
}

# (أ) ترويسة المعاملة كاملة — نشوف كل الأعمدة بما فيها أي بيان/سبب مخفي
RunShow "A) F_Transaction_Header fh_id=1580696" "SELECT * FROM F_Transaction_Header WHERE fh_id=1580696"

# (ب) سطور التفصيل (لو جدول التفصيل بالاسم ده) — هنا غالبًا البيان الحقيقي للصرف
RunShow "B) F_Transaction_Detail fh_id=1580696" "SELECT * FROM F_Transaction_Detail WHERE fh_id=1580696"

# (ج) دليل الحسابات id=65 (اللي بنجيب منه دلوقتي)
RunShow "C) F_Account_Chart ac_id=65" "SELECT ac_id, ac_name_ar FROM F_Account_Chart WHERE ac_id=65"

# (د) مين اللي اسمه «مياه» وفي أنهي جدول/عمود id بتاعه (نجرّب الجداول المرشّحة)
RunShow "D1) F_Account_Chart LIKE مياه" "SELECT ac_id, ac_name_ar FROM F_Account_Chart WHERE ac_name_ar LIKE N'%مياه%'"
RunShow "D2) أي أعمدة id نوع 5 في الترويسة" "SELECT fh_id, fh_from_type, fh_from_id, fh_to_type, fh_to_id, fh_value, fh_notes FROM F_Transaction_Header WHERE fh_id IN (1580696,1580697,1580698) ORDER BY fh_id"

$cn.Close()
Write-Host "`nخلص." -ForegroundColor Green
