# region_writeback.ps1  — محرّك كتابة مناطق العملاء على eplus (الماستر).
# ───────────────────────────────────────────────────────────────────────────
# بيعمل حاجتين فى كل تشغيلة:
#  1) مزامنة المناطق: يقرا Delivery_cost_region من الماستر ويحدّث لقطة
#     Supabase (eplus_delivery_regions) اللى الشاشة بتاخد منها القائمة.  [دايمًا]
#  2) تطبيق الطابور: يقرا customer_region_queue (status=pending) من Supabase،
#     ويكتب cd_region_id على سطر العنوان المطابق فى Customer_Delivery، ويعلّم
#     السطر done/failed.                                          [مع -Apply فقط]
#
# من غير -Apply = عرض بس (preview): بيزامن المناطق ويطبع اللى كان هيتكتب،
# بدون أى تعديل على eplus. المهمة المجدولة بتشغّله بـ-Apply.
#
# الأمان:
#  • بيكتب بس على السطر اللى منطقته فاضية (cd_region_id IS NULL OR =0) — عمرها
#    ما بتلمس عنوان متحدّد قبل كده.
#  • كل الاستعلامات parameterized (العناوين/الأسماء فيها علامات عربى وكوت).
#  • مفتاح service_role بيتقرا من متغيّر البيئة SUPABASE_SERVICE_KEY — **مش**
#    مكتوب فى الريبو (الريبو عام). عيّنه مرة على الماستر:
#        setx SUPABASE_SERVICE_KEY "....."   (ثم افتح PowerShell جديد)
#
# التشغيل:
#    عرض فقط:   .\region_writeback.ps1
#    تطبيق:     .\region_writeback.ps1 -Apply
# (بيطلب باسورد phalix_writer، أو مرّره بـ-Password عشان الجدولة)

param(
  [string]$Server = "localhost,1433",
  [string]$User   = "phalix_writer",
  [System.Security.SecureString]$Password,
  [string]$SbUrl  = "https://rxtjoqulmgkkcohmgzgi.supabase.co",
  [string]$SbKey  = $env:SUPABASE_SERVICE_KEY,
  [switch]$Apply,
  [int]$Max = 200
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function L($m){ Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if ([string]::IsNullOrWhiteSpace($SbKey)) {
  L "وقّف: مفيش SUPABASE_SERVICE_KEY. عيّنه: setx SUPABASE_SERVICE_KEY ""..."" ثم افتح PowerShell جديد."; exit 1
}
if (-not $Password) { $Password = Read-Host "باسورد phalix_writer" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if ([string]::IsNullOrWhiteSpace($pw)) { L "وقّف: الباسورد فاضى."; exit 1 }

# ── Supabase REST helpers ──
$rest = ($SbUrl.TrimEnd('/')) + "/rest/v1"
$H = @{ apikey=$SbKey; Authorization=("Bearer "+$SbKey) }
function SbGet($q){ Invoke-RestMethod -Method Get -Uri ($rest+"/"+$q) -Headers $H }
function SbPatch($q,$obj){
  Invoke-RestMethod -Method Patch -Uri ($rest+"/"+$q) `
    -Headers ($H + @{ 'Content-Type'='application/json'; Prefer='return=minimal' }) `
    -Body ($obj | ConvertTo-Json -Compress) | Out-Null
}
function SbUpsert($table,$rows){
  $json = ($rows | ConvertTo-Json -Compress -Depth 4)
  if(-not $json.StartsWith('[')){ $json = "[$json]" }   # ضمان مصفوفة حتى لو صف واحد
  Invoke-RestMethod -Method Post -Uri ($rest+"/"+$table+"?on_conflict=dc_id") `
    -Headers ($H + @{ 'Content-Type'='application/json'; Prefer='resolution=merge-duplicates,return=minimal' }) `
    -Body $json | Out-Null
}

# ── eplus connection ──
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=25")
try { $cn.Open() } catch { L "فشل الاتصال بـeplus: $($_.Exception.Message)"; exit 1 }
function Scalar($sql,$params){
  $c=$cn.CreateCommand(); $c.CommandText=$sql
  if($params){ foreach($k in $params.Keys){ [void]$c.Parameters.AddWithValue($k,$params[$k]) } }
  return $c.ExecuteScalar()
}
function NonQuery($sql,$params){
  $c=$cn.CreateCommand(); $c.CommandText=$sql
  if($params){ foreach($k in $params.Keys){ [void]$c.Parameters.AddWithValue($k,$params[$k]) } }
  return $c.ExecuteNonQuery()
}

$mode = if($Apply){"تطبيق"}else{"عرض فقط"}
L ("البدء — الوضع: $mode")

# ── (1) مزامنة المناطق إلى Supabase (دايمًا، مش كتابة على eplus) ──
try {
  $c=$cn.CreateCommand()
  $c.CommandText="SELECT dc_id, LTRIM(RTRIM(dc_region_name_ar)) AS nm, dc_delivery_cost FROM Delivery_cost_region WHERE dc_region_name_ar IS NOT NULL AND LTRIM(RTRIM(dc_region_name_ar))<>''"
  $r=$c.ExecuteReader(); $regs=@()
  while($r.Read()){ $regs += @{ dc_id=[int]$r['dc_id']; name=[string]$r['nm']; delivery_cost=$(if($r['dc_delivery_cost'] -is [DBNull]){$null}else{[decimal]$r['dc_delivery_cost']}); synced_at=(Get-Date).ToUniversalTime().ToString("o") } }
  $r.Close()
  if($regs.Count){ SbUpsert "eplus_delivery_regions" $regs }
  L ("مناطق اتزامنت: " + $regs.Count)
} catch { L ("⚠️ مزامنة المناطق فشلت: " + $_.Exception.Message) }

# ── (2) تطبيق الطابور ──
$pending = @()
# ملاحظة: PostgREST بيرجّع [] للطابور الفاضى، و@() بتلفّها لعنصر $null واحد —
# فلازم نفلتر الـnull وإلا بيتعدّ «طلب بكود فاضى» وهمى.
try { $pending = @(SbGet "customer_region_queue?status=eq.pending&order=created_at.asc&limit=$Max" | Where-Object { $_ -and $_.id }) } catch { L ("فشل قراءة الطابور: " + $_.Exception.Message); $cn.Close(); exit 1 }
L ("طلبات معلّقة: " + $pending.Count)

$done=0; $failed=0
foreach($row in $pending){
  $id=$row.id; $code=[string]$row.cust_code; $addr=[string]$row.cust_address; $name=[string]$row.region_name; $dc=$row.dc_id

  # كود العميل لازم رقمى (cd_cust_id = decimal)
  $codeNum = [decimal]0
  if(-not [decimal]::TryParse($code,[ref]$codeNum)){
    L ("  [$code] ✗ كود عميل غير رقمى")
    if($Apply){ SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; result_note='كود عميل غير رقمى'; applied_at=(Get-Date).ToUniversalTime().ToString("o") } }
    $failed++; continue
  }

  # رقم المنطقة: من الشاشة (dc_id) وإلا نحلّله بالاسم على الماستر
  if(-not $dc){
    try { $dc = Scalar "SELECT MIN(dc_id) FROM Delivery_cost_region WHERE LTRIM(RTRIM(dc_region_name_ar))=@n" @{ '@n'=$name } } catch {}
  }
  if(-not $dc -or $dc -is [DBNull]){
    L ("  [$code] ✗ المنطقة غير موجودة: $name")
    if($Apply){ SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; result_note=("منطقة غير موجودة: "+$name); applied_at=(Get-Date).ToUniversalTime().ToString("o") } }
    $failed++; continue
  }
  $dc=[int]$dc

  if(-not $Apply){
    $cnt = Scalar "SELECT COUNT(*) FROM Customer_Delivery WHERE cd_cust_id=@c AND LTRIM(RTRIM(cd_address))=LTRIM(RTRIM(@a)) AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@c'=$codeNum; '@a'=$addr }
    L ("  [عرض][$code] منطقة=$name dc=$dc — عناوين مطابقة فاضية: $cnt — العنوان: $addr")
    continue
  }

  try {
    # تطابق بالعنوان بالظبط (مع تجاهل المسافات الطرفية) + منطقة فاضية فقط
    $n = NonQuery "UPDATE Customer_Delivery SET cd_region_id=@dc, sec_update_uid='region_writeback', sec_update_date=GETDATE() WHERE cd_cust_id=@c AND LTRIM(RTRIM(cd_address))=LTRIM(RTRIM(@a)) AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@dc'=$dc; '@c'=$codeNum; '@a'=$addr }
    $note=$null
    if($n -eq 0){
      # مفيش تطابق بالعنوان: لو للعميل عنوان واحد بس فاضى، نكتبه عليه
      $empty = [int](Scalar "SELECT COUNT(*) FROM Customer_Delivery WHERE cd_cust_id=@c AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@c'=$codeNum })
      if($empty -eq 1){
        $n = NonQuery "UPDATE Customer_Delivery SET cd_region_id=@dc, sec_update_uid='region_writeback', sec_update_date=GETDATE() WHERE cd_cust_id=@c AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@dc'=$dc; '@c'=$codeNum }
        $note="طُبّقت على العنوان الوحيد الفاضى (العنوان النصّى لم يطابق)"
      } else {
        SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; dc_id=$dc; result_note=("لا يوجد عنوان مطابق (فاضى=$empty)"); applied_at=(Get-Date).ToUniversalTime().ToString("o") }
        L ("  [$code] ✗ لا يوجد عنوان مطابق (فاضى=$empty)"); $failed++; continue
      }
    }
    SbPatch "customer_region_queue?id=eq.$id" @{ status='done'; dc_id=$dc; result_note=("صفوف=$n" + $(if($note){" — "+$note}else{""})); applied_at=(Get-Date).ToUniversalTime().ToString("o") }
    L ("  [$code] ✓ $name (صفوف=$n)" + $(if($note){" — "+$note}else{""})); $done++
  } catch {
    try { SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; dc_id=$dc; result_note=("خطأ: "+$_.Exception.Message); applied_at=(Get-Date).ToUniversalTime().ToString("o") } } catch {}
    L ("  [$code] ✗ خطأ: " + $_.Exception.Message); $failed++
  }
}

$cn.Close()
L ("انتهى — تم: $done | فشل: $failed" + $(if(-not $Apply){"  (عرض فقط — مفيش كتابة)"}else{""}))
