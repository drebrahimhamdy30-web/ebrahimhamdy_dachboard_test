# import_purchase_xlsx.ps1
# يستورد تصدير «مشتريات تفصيلي» (Excel) من eplus ويبني قاموس itm_id->كودنا+الاسم.
# الفكرة: eplus بيصدّر الكود والاسم مقروءين (بيفك التشفير)، والمزامنة عندها نفس البنود بالـitm_id.
# بنطابق على (الفرع + pth_id=المسلسل + سعر الشراء + الكمية + **تاريخ الصلاحية**)
# ونملأ item_code_map، وبعدها المشتريات كلها بتترجم تلقائيًا.
# راجع docs/migrate_104_item_code_map.sql و migrate_145.
#
# ⚠️ ليه الصلاحية: السعر والكمية لوحدهم مابيفرقوش بين صنفين في نفس الفاتورة
#    بنفس التسعيرة (شامبو وبلسم)، فالدالة كانت بترفض الاتنين عشان ماتخمّنش —
#    ٦٬٦٧١ بند من ١٣٬٠٤٢ بلا كود كانوا لنفس السبب. الصلاحية بتفرّق بينهم.
#
# ⚠️ وممنوع المطابقة بترتيب السطر: ترتيب التصدير **مش مضمون** — بيتغيّر لو
#    المستخدم رتّب التقرير بعمود تاني قبل التصدير. اتأكد على seyouf/349:
#    الملف (كانتو كير · كافلون · شامبو · بلسم · اسبراي) مخالف لترتيبنا.
#    بنبعت line_no للتشخيص بس، والسيرفر مابيطابقش بيه.
#
# الاستخدام:
#   powershell -File scripts\import_purchase_xlsx.ps1 -Path "H:\My Drive\مشتريات تفصيلى\9-10-2026.xlsx"
#   أو مجلد كامل:  -Path "H:\My Drive\مشتريات تفصيلى"  (بياخد كل ملفات .xlsx)
# الإعدادات (supabaseUrl + serviceKey) من: %USERPROFILE%\.phalix\sync_engine.json

param(
  [Parameter(Mandatory=$true)][string]$Path,
  [int]$Days = 0,   # لو >0: يعالج ملفات .xlsx المعدّلة آخر Days يوم بس (للتشغيل الدوري). 0=الكل.
  [switch]$StageOnly,   # يرفع للـstaging ويقف — من غير ما يبني القاموس (للتحقق قبل الكتابة)
  [string]$ConfigPath = "$env:USERPROFILE\.phalix\sync_engine.json"
)
$ErrorActionPreference='Stop'

# خريطة اسم المخزن في eplus -> كود الفرع عندنا. (san مؤكّد؛ البقية تتأكّد مع أول ملف لكل فرع)
$BRMAP = @{
  'ابراهيم حمدي 2'='san'; 'ابراهيم حمدى 2'='san'
  'السيوف'='seyouf'
  'الصيدلية'='mamora'
  'ابراهيم حمدي 3'='bishr'; 'ابراهيم حمدى 3'='bishr'
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$base = $cfg.supabaseUrl; $key = $cfg.serviceKey
$H = @{ apikey=$key; Authorization="Bearer $key"; 'Content-Type'='application/json' }

function Parse-Xlsx([string]$file){
  $x = New-Object -ComObject Excel.Application; $x.Visible=$false; $x.DisplayAlerts=$false
  try {
    $wb = $x.Workbooks.Open($file,[Type]::Missing,$true)   # read-only
    $ws = $wb.Sheets.Item(1)
    $arr = $ws.UsedRange.Value2                            # المدى كله في نداء واحد (سريع)
    $wb.Close($false)
    $rows = $arr.GetLength(0); $cols = $arr.GetLength(1)
    $recs = New-Object System.Collections.Generic.List[object]
    $branch=$null; $curPth=$null; $stores=@{}; $lineNo=0
    for($r=1;$r -le $rows;$r++){
      $s1 = "$($arr.GetValue($r,1))".Trim()
      $s2 = if($cols -ge 2){ "$($arr.GetValue($r,2))".Trim() } else { '' }
      # سطر قسم فرع: c2=موردين/أفراد و c1 اسم مخزن معروف
      if(($s2 -eq 'موردين' -or $s2 -eq 'أفراد') -and $BRMAP.ContainsKey($s1)){ $branch=$BRMAP[$s1]; $stores[$s1]=$branch; continue }
      # سطر «ملاحظات» = بداية فاتورة جديدة → المسلسل والعدّاد يتصفّر
      if($s1 -eq 'ملاحظات'){ $curPth = $arr.GetValue($r,24); $lineNo=0; continue }
      $code = if($cols -ge 18){ $arr.GetValue($r,18) } else { $null }
      $name = if($cols -ge 17){ "$($arr.GetValue($r,17))".Trim() } else { '' }
      if($branch -and $curPth -ne $null -and $code -ne $null -and $name -ne '' -and ($code -is [double] -or "$code" -match '^\d+$')){
        $lineNo++
        # عمود 15 = ت.صلاحية كرقم إكسل تسلسلي (ممكن يكون فاضي لأصناف بلا صلاحية)
        $expRaw = if($cols -ge 15){ $arr.GetValue($r,15) } else { $null }
        $exp = $null
        if($expRaw -is [double] -and $expRaw -gt 0){
          try { $exp = [DateTime]::FromOADate($expRaw).ToString('yyyy-MM-dd') } catch { $exp = $null }
        }
        $recs.Add([pscustomobject]@{
          branch=$branch; pth_id=[int64]$curPth; code="$([int64]$code)"; name=$name
          qty=[double]$arr.GetValue($r,12); pur=[double]$arr.GetValue($r,6)
          line_no=$lineNo; exp_date=$exp
        })
      }
    }
    $stxt = ($stores.Keys | ForEach-Object { "$_=$($stores[$_])" }) -join ', '
    Write-Host ("  {0}: [{1}] | {2} بند" -f (Split-Path $file -Leaf), $stxt, $recs.Count)
    return $recs
  } finally { $x.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($x)|Out-Null }
}

# اجمع الملفات
if(Test-Path $Path -PathType Container){
  $gc = Get-ChildItem $Path -Filter *.xlsx
  if($Days -gt 0){ $gc = $gc | Where-Object { $_.LastWriteTime -ge (Get-Date).AddDays(-$Days) } }
  $files = $gc | Select-Object -Expand FullName
} else { $files = ,$Path }
if(-not $files){ Write-Host "مفيش ملفات مطابقة."; exit 0 }
$all=@()
foreach($f in $files){ $all += Parse-Xlsx $f }
if($all.Count -eq 0){ Write-Host "مفيش بنود."; exit 0 }
Write-Host ("إجمالي البنود: {0}" -f $all.Count)

# نظّف الـstaging ثم ارفع
Invoke-RestMethod -Method Delete -Uri "$base/rest/v1/purchase_xlsx_stage?pth_id=gte.0" -Headers ($H + @{Prefer='return=minimal'}) | Out-Null
$batch=500
for($i=0;$i -lt $all.Count;$i+=$batch){
  $chunk = $all[$i..([Math]::Min($i+$batch-1,$all.Count-1))]
  $body = $chunk | ConvertTo-Json -Depth 3; if($chunk.Count -eq 1){ $body="[$body]" }
  Invoke-RestMethod -Method Post -Uri "$base/rest/v1/purchase_xlsx_stage" -Headers ($H + @{Prefer='return=minimal'}) -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}
Write-Host "اترفعوا للـstaging."
if($StageOnly){ Write-Host "StageOnly: وقفت من غير ما أبني القاموس."; exit 0 }
Write-Host "بابني القاموس..."

# ابنِ القاموس وطبّقه
$res = Invoke-RestMethod -Method Post -Uri "$base/rest/v1/rpc/build_purchase_code_map" -Headers $H -Body '{}'
Write-Host ("تم: اتكوّد/اتحدّث {0} صنف، واتطبّق على {1} بند." -f $res.mapped, $res.applied)
