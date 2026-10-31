# region_writeback.ps1  — محرّك مناطق العملاء على eplus (الماستر).
# ───────────────────────────────────────────────────────────────────────────
# فى كل تشغيلة بيعمل 3 حاجات:
#  1) مزامنة المناطق  → eplus_delivery_regions (قائمة الشاشة).            [دايمًا]
#  2) مزامنة عناوين التوصيل الفاضية للعملاء المحتاجين منطقة من eplus
#     → customer_delivery_pending (مصدر الشاشة: الاسم + العنوان الحقيقى).   [دايمًا]
#     (العنوان مش موجود فى طلباتنا — بييجى من eplus Customer_Delivery.)
#  3) تطبيق الطابور customer_region_queue → كتابة cd_region_id على
#     سطر العنوان بالظبط (cd_id).                                   [مع -Apply فقط]
#
# من غير -Apply = عرض بس: بيزامن (1)+(2) ويطبع اللى كان هيتكتب، بدون تعديل eplus.
#
# الأمان: بيكتب بس على سطر منطقته فاضية (cd_region_id IS NULL OR =0)؛ استعلامات
# parameterized؛ مفتاح service_role من $env:SUPABASE_SERVICE_KEY (مش فى الريبو).
#
# التشغيل:  عرض:  .\region_writeback.ps1      تطبيق:  .\region_writeback.ps1 -Apply

param(
  [string]$Server = "localhost,1433",
  [string]$User   = "phalix_writer",
  [System.Security.SecureString]$Password,
  [string]$SbUrl  = "https://rxtjoqulmgkkcohmgzgi.supabase.co",
  [string]$SbKey  = $env:SUPABASE_SERVICE_KEY,
  [string]$Placeholder = "يحتاج إضافة منطقة",
  [string]$Cutoff = "2026-10-30T00:00:00+02:00",
  [switch]$Apply,
  [int]$Max = 500
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function L($m){ Write-Host ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function NowUtc(){ (Get-Date).ToUniversalTime().ToString("o") }

if ([string]::IsNullOrWhiteSpace($SbKey)) {
  L "وقّف: مفيش SUPABASE_SERVICE_KEY. عيّنه: `$env:SUPABASE_SERVICE_KEY='...'  (أو setx للجدولة)"; exit 1
}
if (-not $Password) { $Password = Read-Host "باسورد phalix_writer" -AsSecureString }
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
if ([string]::IsNullOrWhiteSpace($pw)) { L "وقّف: الباسورد فاضى."; exit 1 }

# ── Supabase REST (الرفع UTF-8 عشان العربى مايتبوّظش) ──
$rest = ($SbUrl.TrimEnd('/')) + "/rest/v1"
$H = @{ apikey=$SbKey; Authorization=("Bearer "+$SbKey) }
function SbGet($q){ Invoke-RestMethod -Method Get -Uri ($rest+"/"+$q) -Headers $H }
function SbBody($method,$q,$json,$prefer){
  $hdr = @{ apikey=$SbKey; Authorization=("Bearer "+$SbKey); 'Content-Type'='application/json; charset=utf-8' }
  if($prefer){ $hdr['Prefer']=$prefer }
  Invoke-RestMethod -Method $method -Uri ($rest+"/"+$q) -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
}
function SbUpsert($table,$onconf,$rows){
  $json = ($rows | ConvertTo-Json -Compress -Depth 5); if(-not $json.StartsWith('[')){ $json="[$json]" }
  SbBody 'Post' ($table+"?on_conflict="+$onconf) $json 'resolution=merge-duplicates,return=minimal'
}
function SbPatch($q,$obj){ SbBody 'Patch' $q ($obj|ConvertTo-Json -Compress) 'return=minimal' }
function SbDelete($q){ Invoke-RestMethod -Method Delete -Uri ($rest+"/"+$q) -Headers ($H + @{ Prefer='return=minimal' }) | Out-Null }
function SbRpc($fn,$obj){
  $hdr = @{ apikey=$SbKey; Authorization=("Bearer "+$SbKey); 'Content-Type'='application/json; charset=utf-8' }
  Invoke-RestMethod -Method Post -Uri ($rest+"/rpc/"+$fn) -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes(($obj|ConvertTo-Json -Compress)))
}

# ── eplus ──
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Genius;User ID=$User;Password=$pw;Connect Timeout=25")
try { $cn.Open() } catch { L "فشل الاتصال بـeplus: $($_.Exception.Message)"; exit 1 }
function Scalar($sql,$params){ $c=$cn.CreateCommand(); $c.CommandText=$sql; if($params){foreach($k in $params.Keys){[void]$c.Parameters.AddWithValue($k,$params[$k])}}; return $c.ExecuteScalar() }
function NonQuery($sql,$params){ $c=$cn.CreateCommand(); $c.CommandText=$sql; if($params){foreach($k in $params.Keys){[void]$c.Parameters.AddWithValue($k,$params[$k])}}; return $c.ExecuteNonQuery() }

L ("البدء — الوضع: " + $(if($Apply){"تطبيق"}else{"عرض فقط"}))
$runStart = NowUtc

# ── (1) مزامنة المناطق ──
try {
  $c=$cn.CreateCommand()
  $c.CommandText="SELECT dc_id, LTRIM(RTRIM(dc_region_name_ar)) AS nm, dc_delivery_cost FROM Delivery_cost_region WHERE dc_region_name_ar IS NOT NULL AND LTRIM(RTRIM(dc_region_name_ar))<>''"
  $r=$c.ExecuteReader(); $regs=@()
  while($r.Read()){ $regs += @{ dc_id=[int]$r['dc_id']; name=[string]$r['nm']; delivery_cost=$(if($r['dc_delivery_cost'] -is [DBNull]){$null}else{[decimal]$r['dc_delivery_cost']}); synced_at=$runStart } }
  $r.Close()
  for($i=0;$i -lt $regs.Count;$i+=200){ SbUpsert "eplus_delivery_regions" "dc_id" ($regs[$i..([Math]::Min($i+199,$regs.Count-1))]) }
  L ("مناطق اتزامنت: " + $regs.Count)
} catch { L ("⚠️ مزامنة المناطق فشلت: " + $_.Exception.Message) }

# ── (2) مزامنة عناوين التوصيل الفاضية للعملاء المحتاجين منطقة ──
try {
  # العملاء المحتاجين منطقة عبر RPC (تجميع سيرفر — بلا عربى فى الـURL)
  $custs=@(SbRpc "pending_region_customers" @{ p_since=$Cutoff } | Where-Object { $_ -and $_.cust_code })
  $cmap=@{}
  foreach($o in $custs){ $cmap[[string]$o.cust_code]=[pscustomobject]@{ branch=$o.branch_id; cnt=[int]$o.order_count } }
  $cdp=@()
  foreach($cc in @($cmap.Keys)){
    $cnum=[decimal]0; if(-not [decimal]::TryParse([string]$cc,[ref]$cnum)){ continue }
    $cmd=$cn.CreateCommand()
    $cmd.CommandText="SELECT d.cd_id, LTRIM(RTRIM(d.cd_address)) AS addr, LTRIM(RTRIM(cu.cust_name_ar)) AS nm FROM Customer_Delivery d LEFT JOIN Customer cu ON cu.cust_id=d.cd_cust_id WHERE d.cd_cust_id=@c AND (d.cd_region_id IS NULL OR d.cd_region_id=0)"
    [void]$cmd.Parameters.AddWithValue('@c',$cnum)
    $rd=$cmd.ExecuteReader()
    while($rd.Read()){
      $cdId = [int][decimal]$rd['cd_id']
      $cdp += [pscustomobject]@{ cust_code=[string]$cc; cd_id=$cdId; cust_name=[string]$rd['nm']; cd_address=[string]$rd['addr']; branch_id=$cmap[$cc].branch; order_count=$cmap[$cc].cnt; synced_at=$runStart }
    }
    $rd.Close()
  }
  $cdpArr=@($cdp)
  for($i=0;$i -lt $cdpArr.Count;$i+=200){ SbUpsert "customer_delivery_pending" "cust_code,cd_id" ($cdpArr[$i..([Math]::Min($i+199,$cdpArr.Count-1))]) }
  # مسح القديم (اتكتب أو خرج من القائمة): أى صف ماتلمسش فى الجولة دى
  SbDelete ("customer_delivery_pending?synced_at=lt."+[uri]::EscapeDataString($runStart))
  L ("عملاء محتاجين منطقة: " + $cmap.Count + " — عناوين فاضية: " + $cdpArr.Count)
} catch { L ("⚠️ مزامنة العناوين فشلت (سطر " + $_.InvocationInfo.ScriptLineNumber + "): " + $_.Exception.Message) }

# ── (3) تطبيق الطابور ──
$pending=@()
try { $pending=@(SbGet "customer_region_queue?status=eq.pending&order=created_at.asc&limit=$Max" | Where-Object { $_ -and $_.id }) } catch { L ("فشل قراءة الطابور: " + $_.Exception.Message); $cn.Close(); exit 1 }
L ("طلبات معلّقة: " + $pending.Count)

$done=0; $failed=0
foreach($row in $pending){
  $id=$row.id; $code=[string]$row.cust_code; $name=[string]$row.region_name; $dc=$row.dc_id; $cdid=$row.cd_id; $addr=[string]$row.cust_address
  $codeNum=[decimal]0
  if(-not [decimal]::TryParse($code,[ref]$codeNum)){
    if($Apply){ SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; result_note='كود عميل غير رقمى'; applied_at=(NowUtc) } }
    L ("  [$code] ✗ كود غير رقمى"); $failed++; continue
  }
  if(-not $dc){ try { $dc = Scalar "SELECT MIN(dc_id) FROM Delivery_cost_region WHERE LTRIM(RTRIM(dc_region_name_ar))=@n" @{ '@n'=$name } } catch {} }
  if(-not $dc -or $dc -is [DBNull]){
    if($Apply){ SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; result_note=("منطقة غير موجودة: "+$name); applied_at=(NowUtc) } }
    L ("  [$code] ✗ المنطقة غير موجودة: $name"); $failed++; continue
  }
  $dc=[int]$dc

  if(-not $Apply){
    if($cdid){ L ("  [عرض][$code] cd_id=$cdid → $name (dc=$dc)") }
    else { $cnt=[int](Scalar "SELECT COUNT(*) FROM Customer_Delivery WHERE cd_cust_id=@c AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@c'=$codeNum }); L ("  [عرض][$code] (بلا cd_id) فاضى=$cnt → $name (dc=$dc)") }
    continue
  }

  try {
    $n=0; $note=$null
    if($cdid){
      $n = NonQuery "UPDATE Customer_Delivery SET cd_region_id=@dc, sec_update_uid='region_writeback', sec_update_date=GETDATE() WHERE cd_cust_id=@c AND cd_id=@cd AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@dc'=$dc; '@c'=$codeNum; '@cd'=[int]$cdid }
      if($n -eq 0){
        SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; dc_id=$dc; result_note=("السطر اتكتب قبل كده أو مش فاضى (cd_id=$cdid)"); applied_at=(NowUtc) }
        L ("  [$code] ✗ cd_id=$cdid مش فاضى"); $failed++; continue
      }
    } else {
      # توافق خلفى: صف طابور قديم بلا cd_id — نحاول بالعنوان ثم العنوان الوحيد الفاضى
      $n = NonQuery "UPDATE Customer_Delivery SET cd_region_id=@dc, sec_update_uid='region_writeback', sec_update_date=GETDATE() WHERE cd_cust_id=@c AND LTRIM(RTRIM(cd_address))=LTRIM(RTRIM(@a)) AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@dc'=$dc; '@c'=$codeNum; '@a'=$addr }
      if($n -eq 0){
        $empty=[int](Scalar "SELECT COUNT(*) FROM Customer_Delivery WHERE cd_cust_id=@c AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@c'=$codeNum })
        if($empty -eq 1){ $n = NonQuery "UPDATE Customer_Delivery SET cd_region_id=@dc, sec_update_uid='region_writeback', sec_update_date=GETDATE() WHERE cd_cust_id=@c AND (cd_region_id IS NULL OR cd_region_id=0)" @{ '@dc'=$dc; '@c'=$codeNum }; $note="عنوان وحيد فاضى" }
        else { SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; dc_id=$dc; result_note=("لا يوجد عنوان مطابق (فاضى=$empty)"); applied_at=(NowUtc) }; L ("  [$code] ✗ لا يوجد عنوان مطابق (فاضى=$empty)"); $failed++; continue }
      }
    }
    SbPatch "customer_region_queue?id=eq.$id" @{ status='done'; dc_id=$dc; result_note=("صفوف=$n"+$(if($note){" — "+$note}else{""})); applied_at=(NowUtc) }
    L ("  [$code] ✓ $name (صفوف=$n)"+$(if($note){" — "+$note}else{""})); $done++
  } catch {
    try { SbPatch "customer_region_queue?id=eq.$id" @{ status='failed'; dc_id=$dc; result_note=("خطأ: "+$_.Exception.Message); applied_at=(NowUtc) } } catch {}
    L ("  [$code] ✗ خطأ: " + $_.Exception.Message); $failed++
  }
}

$cn.Close()
L ("انتهى — تم: $done | فشل: $failed" + $(if(-not $Apply){"  (عرض فقط — مفيش كتابة)"}else{""}))
