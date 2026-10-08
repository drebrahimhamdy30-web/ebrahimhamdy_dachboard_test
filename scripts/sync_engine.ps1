# sync_engine.ps1 — محرّك المزامنة العام (مركز المزامنة)
# بيقرا المهام من Supabase (sync_jobs) وينفّذ اللي حان وقته + أي طلبات (زامن الآن / سحب فترة).
# قراءة فقط من eplus (READ UNCOMMITTED = بدون أي قفل على نظام البيع). Upsert لـSupabase.
# بيتجدول كـ«نبضة» كل دقيقة–دقيقتين (schtasks). كل مهمة بجدولتها الخاصة في الجدول.
#
# الإعدادات (أسرار، مش في الريبو): C:\ProgramData\phalix\sync_engine.json
# {
#   "supabaseUrl":"https://rxtjoqulmgkkcohmgzgi.supabase.co",
#   "serviceKey":"<SERVICE_ROLE_KEY>",
#   "branches":{
#     "mamora":{"server":"localhost,1433","user":"phalix_reader","password":"..."},
#     "san":   {"server":"192.168.192.225,1433","user":"phalix_reader","password":"..."},
#     "bishr": {"server":"192.168.192.80,1433","user":"phalix_reader","password":"..."},
#     "seyouf":{"server":"192.168.192.44,1433","user":"phalix_reader","password":"..."}
#   }
# }

param([string]$ConfigPath = "C:\ProgramData\phalix\sync_engine.json")
$ErrorActionPreference = "Stop"
$logPath = [System.IO.Path]::ChangeExtension($ConfigPath, ".log")
$inv = [Globalization.CultureInfo]::InvariantCulture
function Log($m){ $l = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; Add-Content $logPath $l; Write-Host $l }

try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { Log "FATAL config: $($_.Exception.Message)"; exit 1 }
$SB = $cfg.supabaseUrl.TrimEnd('/')
$Hdr = @{ apikey=$cfg.serviceKey; Authorization="Bearer $($cfg.serviceKey)"; "Content-Type"="application/json" }

function Sb-Get($path){ try{ Invoke-RestMethod -Uri "$SB/rest/v1/$path" -Headers $Hdr -Method Get }catch{ throw "GET $path -> $($_.Exception.Message)" } }
function Sb-Patch($path,$obj){ $h=$Hdr.Clone(); $h["Prefer"]="return=minimal"; try{ Invoke-RestMethod -Uri "$SB/rest/v1/$path" -Headers $h -Method Patch -Body ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $obj -Compress))) | Out-Null }catch{ throw "PATCH $path -> $($_.Exception.Message)" } }
function Sb-Insert($table,$obj){ $h=$Hdr.Clone(); $h["Prefer"]="return=minimal"; try{ Invoke-RestMethod -Uri "$SB/rest/v1/$table" -Headers $h -Method Post -Body ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @($obj) -Compress))) | Out-Null }catch{ throw "POST $table -> $($_.Exception.Message)" } }
function Sb-Upsert($table,$conflict,$rows){
  if(-not $rows -or $rows.Count -eq 0){ return 0 }
  $h=$Hdr.Clone(); $h["Prefer"]="resolution=merge-duplicates,return=minimal"; $u="$SB/rest/v1/${table}?on_conflict=$conflict"; $sent=0
  for($i=0;$i -lt $rows.Count;$i+=500){
    $chunk=$rows[$i..([Math]::Min($i+499,$rows.Count-1))]
    $body=ConvertTo-Json @($chunk) -Depth 4 -Compress
    try{ Invoke-RestMethod -Uri $u -Headers $h -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null }catch{ throw "UPSERT $u -> $($_.Exception.Message)" }
    $sent+=$chunk.Count
  }
  return $sent
}
function OpenSql($branch){
  $b=$cfg.branches.$branch
  if(-not $b){ throw "لا يوجد إعداد اتصال للفرع $branch" }
  $cn=New-Object System.Data.SqlClient.SqlConnection("Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=30")
  $cn.Open()
  $c=$cn.CreateCommand(); $c.CommandText="SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"; [void]$c.ExecuteNonQuery()
  return $cn
}
function Scalar($cn,$sql){ $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60; $v=$c.ExecuteScalar(); if($v -is [DBNull]){ return $null }; return $v }
function Rows($cn,$sql){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=180
  $r=$c.ExecuteReader(); $out=New-Object System.Collections.Generic.List[object]
  while($r.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $r.FieldCount;$i++){ $n=$r.GetName($i); $v=$r.GetValue($i)
      if($v -is [DBNull]){ $o[$n]=$null } elseif($v -is [datetime]){ $o[$n]=([datetime]$v).ToString('yyyy-MM-ddTHH:mm:ss') } else { $o[$n]=$v } }
    $out.Add([pscustomobject]$o) }
  $r.Close(); return ,$out.ToArray()
}
function Subst($tpl,$map){ $s=$tpl; foreach($k in $map.Keys){ $s=$s.Replace("{$k}",[string]$map[$k]) }; return $s }

# تشغيل مهمة لفرع واحد. mode: incr | backfill. بترجّع hashtable بالنتائج.
function Run-JobBranch($job, $branch, $mode, $from, $to){
  $res=@{ new=0; items=0; status='ok'; error=$null }
  $cn=$null
  try{
    $cn=OpenSql $branch
    $state = (Sb-Get "sync_branch_state?job_id=eq.$($job.id)&branch=eq.$branch&select=last_pth,last_window_at")
    $lastPth = if($state){ [int64]$state[0].last_pth } else { 0 }
    $lastWin = if($state -and $state[0].last_window_at){ [datetimeoffset]::Parse($state[0].last_window_at).UtcDateTime } else { [datetime]::MinValue }
    $nowU=(Get-Date).ToUniversalTime()
    $cut=(Get-Date).AddDays(-[int]$job.window_days).ToString('yyyy-MM-dd HH:mm:ss')
    # المود + أي فلتر
    $whereKey=$null; $curMax=$null
    if($mode -eq 'backfill'){ $whereKey='where_range' }
    else{
      $probe = ($job.steps | Where-Object { $_.probe_max } | Select-Object -First 1)
      if($probe){ $curMax = Scalar $cn $probe.probe_max; if($null -ne $curMax){ $curMax=[int64]$curMax } }
      $doWindow = ($lastWin -eq [datetime]::MinValue) -or (($nowU - $lastWin).TotalMinutes -ge [int]$job.window_refresh_minutes)
      if((-not $doWindow) -and ($null -ne $curMax) -and ($curMax -eq $lastPth)){
        if($cn){ $cn.Close() }
        Sb-Patch "sync_branch_state?job_id=eq.$($job.id)&branch=eq.$branch" @{ last_sync_at=(Get-Date).ToUniversalTime().ToString('o'); last_status='empty'; rows_last=0; updated_at=(Get-Date).ToUniversalTime().ToString('o') }
        $res.status='empty'; return $res
      }
      $whereKey = if($doWindow){ 'where_window' } else { 'where_new' }
    }
    $map=@{ branch=$branch; cut=$cut; last_pth=$lastPth; from=$from; to=$to }
    foreach($st in $job.steps){
      $sql = Subst $st.select $map
      $clause = $st.$whereKey
      if($clause){ $sql = $sql + " WHERE (" + (Subst $clause $map) + ")" }
      $rows = Rows $cn $sql
      $n = Sb-Upsert $st.target $st.conflict $rows
      if($st.target -eq 'purchase_invoices'){ $res.new=$n } elseif($st.target -eq 'purchase_invoice_items'){ $res.items=$n }
    }
    $cn.Close(); $cn=$null
    # تحديث الـwatermark (للتزايدي فقط)
    $patch=@{ last_sync_at=(Get-Date).ToUniversalTime().ToString('o'); last_status='ok'; rows_last=$res.new; updated_at=(Get-Date).ToUniversalTime().ToString('o') }
    if($mode -ne 'backfill'){
      if($null -ne $curMax -and $curMax -gt $lastPth){ $patch.last_pth=$curMax }
      if($whereKey -eq 'where_window'){ $patch.last_window_at=(Get-Date).ToUniversalTime().ToString('o') }
    }
    Sb-Patch "sync_branch_state?job_id=eq.$($job.id)&branch=eq.$branch" $patch
  } catch {
    $res.status='error'; $res.error=($_.Exception.Message -split "`n")[0]
    try{ if($cn){ $cn.Close() } }catch{}
    try{ Sb-Patch "sync_branch_state?job_id=eq.$($job.id)&branch=eq.$branch" @{ last_status='error'; updated_at=(Get-Date).ToUniversalTime().ToString('o') } }catch{}
  }
  return $res
}
function LogRun($job,$branch,$kind,$res,$ms){
  try{ Sb-Insert "sync_runs" @{ job_id=$job.id; branch=$branch; kind=$kind; new_rows=$res.new; item_rows=$res.items; duration_ms=$ms; status=$res.status; error=$res.error } }catch{}
}

Log "=== نبضة المحرّك ==="
$jobs = Sb-Get "sync_jobs?select=*"

# 1) الطلبات المعلّقة (زامن الآن / سحب فترة)
$reqs = Sb-Get "sync_requests?status=eq.pending&select=*&order=requested_at.asc"
foreach($rq in $reqs){
  $job = $jobs | Where-Object { $_.id -eq $rq.job_id } | Select-Object -First 1
  if(-not $job){ Sb-Patch "sync_requests?id=eq.$($rq.id)" @{ status='error'; message='مهمة غير موجودة'; done_at=(Get-Date).ToUniversalTime().ToString('o') }; continue }
  Sb-Patch "sync_requests?id=eq.$($rq.id)" @{ status='running' }
  $branches = if($rq.branch){ @($rq.branch) } else { (Sb-Get "sync_branch_state?job_id=eq.$($job.id)&enabled=eq.true&select=branch" | ForEach-Object { $_.branch }) }
  $mode = if($rq.kind -eq 'backfill'){ 'backfill' } else { 'incr' }
  foreach($br in $branches){
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $res = Run-JobBranch $job $br $mode $rq.from_date $rq.to_date
    $sw.Stop(); LogRun $job $br $rq.kind $res $sw.ElapsedMilliseconds
    Log ("طلب[{0}] {1}/{2}: {3} فواتير={4} بنود={5} {6}" -f $rq.kind,$job.id,$br,$res.status,$res.new,$res.items,$res.error)
  }
  if($job.post_rpc){ try{ Invoke-RestMethod -Uri "$SB/rest/v1/rpc/$($job.post_rpc)" -Headers $Hdr -Method Post -Body "{}" | Out-Null }catch{} }
  Sb-Patch "sync_requests?id=eq.$($rq.id)" @{ status='done'; done_at=(Get-Date).ToUniversalTime().ToString('o') }
}

# 2) المهام المجدولة اللي حان وقتها
foreach($job in ($jobs | Where-Object { $_.enabled })){
  $due = $true
  if($job.last_run_at){ $due = ((Get-Date).ToUniversalTime() - [datetimeoffset]::Parse($job.last_run_at).UtcDateTime).TotalMinutes -ge [int]$job.interval_minutes }
  if(-not $due){ continue }
  $branches = Sb-Get "sync_branch_state?job_id=eq.$($job.id)&enabled=eq.true&select=branch" | ForEach-Object { $_.branch }
  $anyNew=$false
  foreach($br in $branches){
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $res = Run-JobBranch $job $br 'incr' $null $null
    $sw.Stop()
    if($res.status -ne 'empty'){ LogRun $job $br 'auto' $res $sw.ElapsedMilliseconds; $anyNew=$true }
    if($res.status -ne 'empty'){ Log ("[{0}/{1}] {2} فواتير={3} بنود={4} {5}" -f $job.id,$br,$res.status,$res.new,$res.items,$res.error) }
  }
  if($anyNew -and $job.post_rpc){ try{ Invoke-RestMethod -Uri "$SB/rest/v1/rpc/$($job.post_rpc)" -Headers $Hdr -Method Post -Body "{}" | Out-Null }catch{} }
  Sb-Patch "sync_jobs?id=eq.$($job.id)" @{ last_run_at=(Get-Date).ToUniversalTime().ToString('o'); last_status='ok' }
}
Log "=== انتهت النبضة ==="



