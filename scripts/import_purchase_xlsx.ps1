# import_purchase_xlsx.ps1
# يستورد تصدير «مشتريات تفصيلي» (Excel) من eplus ويبني قاموس itm_id->كودنا+الاسم.
# الفكرة: eplus بيصدّر الكود والاسم مقروءين (بيفك التشفير)، والمزامنة عندها نفس البنود بالـitm_id.
# بنطابق على (الفرع + pth_id=المسلسل + سعر الشراء + الكمية) ونملأ item_code_map، وبعدها المشتريات
# كلها بتترجم تلقائيًا. راجع docs/migrate_104_item_code_map.sql.
#
# الاستخدام:
#   powershell -File scripts\import_purchase_xlsx.ps1 -Path "H:\My Drive\مشتريات تفصيلى\9-10-2026.xlsx"
#   أو مجلد كامل:  -Path "H:\My Drive\مشتريات تفصيلى"  (بياخد كل ملفات .xlsx)
# الإعدادات (supabaseUrl + serviceKey) من: %USERPROFILE%\.phalix\sync_engine.json

param(
  [Parameter(Mandatory=$true)][string]$Path,
  [int]$Days = 0,   # لو >0: يعالج ملفات .xlsx المعدّلة آخر Days يوم بس (للتشغيل الدوري). 0=الكل.
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
    $wb = $x.Workbooks.Open($file); $ws = $wb.Sheets.Item(1)
    $rc = $ws.UsedRange.Rows.Count
    $store = "$($ws.Cells.Item(2,1).Value2)".Trim()
    $branch = $BRMAP[$store]
    if(-not $branch){ Write-Warning "مخزن غير معروف: '$store' في $file — اتخطّى"; return @() }
    $recs=@(); $curPth=$null
    for($r=1;$r -le $rc;$r++){
      $c1=$ws.Cells.Item($r,1).Value2
      if("$c1".Trim() -eq 'ملاحظات'){ $curPth=$ws.Cells.Item($r,24).Value2; continue }
      $code=$ws.Cells.Item($r,18).Value2; $name=$ws.Cells.Item($r,17).Value2
      if($code -ne $null -and $name -ne $null -and ("$name".Trim() -ne '') -and ($code -is [double] -or "$code" -match '^\d+$') -and $curPth -ne $null){
        $recs += [pscustomobject]@{
          branch=$branch; pth_id=[int64]$curPth; code="$([int64]$code)"; name=("$name".Trim())
          qty=[double]$ws.Cells.Item($r,12).Value2; pur=[double]$ws.Cells.Item($r,6).Value2
        }
      }
    }
    $wb.Close($false)
    Write-Host ("  {0}: مخزن '{1}' -> فرع {2} | {3} بند" -f (Split-Path $file -Leaf), $store, $branch, $recs.Count)
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
Write-Host "اترفعوا للـstaging. بابني القاموس..."

# ابنِ القاموس وطبّقه
$res = Invoke-RestMethod -Method Post -Uri "$base/rest/v1/rpc/build_purchase_code_map" -Headers $H -Body '{}'
Write-Host ("تم: اتكوّد/اتحدّث {0} صنف، واتطبّق على {1} بند." -f $res.mapped, $res.applied)
