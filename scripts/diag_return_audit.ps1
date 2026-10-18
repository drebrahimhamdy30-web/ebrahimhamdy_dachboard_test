# diag_return_audit.ps1 — هل eplus بيسجّل تاريخ/وقت/مستخدم لمرتجع المورّد؟ قراءة فقط.
#
#  الخلفية: المرتجع بيتعمل بطريقتين —
#    ١) مستند مرتجع (Item_back_h/d) → فيه تاريخ ووقت ومستخدم وسبب. موثّق بالكامل.
#    ٢) تعديل سطر الفاتورة (pur_trans_d.itm_back_qty) → مجرد رقم في خانة،
#       ومالقيناش معاه أي تاريخ. ودي الغالبية (13 مقابل 7 لفارما في سبتمبر/أكتوبر).
#
#  السكربت ده بيدوّر على إجابة سؤال واحد:
#    هل في مكان تاني في eplus بيسجّل «مين عدّل الفاتورة وامتى» بدقة؟
#
#  بيعمل ٦ فحوص:
#    ١) كل أعمدة pur_trans_d و pur_trans_h — يمكن فيه عمود تاريخ مرتجع
#       إحنا مش بنسحبه أصلًا (المزامنة بتسحب أعمدة محددة مش *)
#    ٢) كل أعمدة Item_back_h و Item_back_d — للمقارنة
#    ٣) أي جدول في القاعدة اسمه فيه log/audit/hist/trace/track
#    ٤) أي جدول فيه عمود اسمه فيه pth أو ptd (مرجع لفاتورة الشراء)
#    ٥) أي تريجر على pur_trans_d أو pur_trans_h
#    ٦) ترجمة أرقام المستخدمين (60 / 239 / 334) لأسماء من Employee
#
#  ⚠️ مابيكتبش أي حاجة. READ UNCOMMITTED زي محرّك المزامنة.
#     لازم يتشغّل على جهاز الصيدلية (اللي فيه ملف الإعدادات والاتصال بالسيرفر).
#
#   .\diag_return_audit.ps1
#   .\diag_return_audit.ps1 -Branch san -Out C:\temp\audit.txt

param(
  [string]$ConfigPath = "C:\ProgramData\phalix\sync_engine.json",
  [string]$Branch     = "mamora",
  [string]$Out        = "$env:TEMP\diag_return_audit.txt"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$lines = New-Object System.Collections.Generic.List[string]
function Say($m){ Write-Host $m; $lines.Add($m) }

try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
catch { Write-Host "تعذّر قراءة الإعدادات: $ConfigPath"; exit 1 }

$b = $cfg.branches.$Branch
if (-not $b) { Write-Host "الفرع '$Branch' مش في الإعدادات"; exit 1 }

$cn = New-Object System.Data.SqlClient.SqlConnection(
  "Server=$($b.server);Database=Genius;User ID=$($b.user);Password=$($b.password);Connect Timeout=20")
try { $cn.Open() }
catch { Write-Host "فشل الاتصال بـ$($b.server): $($_.Exception.Message.Split([char]10)[0])"; exit 1 }
$c0 = $cn.CreateCommand(); $c0.CommandText = "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"
$c0.ExecuteNonQuery() | Out-Null

# بيرجّع الصفوف كنص مرتّب. SQL Server 2000: TOP مش OFFSET، و sysobjects مش sys.tables.
function Q($sql, $label) {
  Say ""
  Say "--- $label"
  try {
    $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 180
    $r = $c.ExecuteReader()
    $n = 0
    while ($r.Read()) {
      $parts = @()
      for ($i = 0; $i -lt $r.FieldCount; $i++) {
        $v = $r.GetValue($i)
        if ($v -is [DBNull]) { $v = "—" }
        $parts += ("{0}={1}" -f $r.GetName($i), $v)
      }
      Say ("   " + ($parts -join "  |  "))
      $n++
    }
    $r.Close()
    if ($n -eq 0) { Say "   (مفيش نتائج)" }
  } catch {
    Say "   [فشل] $($_.Exception.Message.Split([char]10)[0].Trim())"
  }
}

Say "=========================================================="
Say " فحص توثيق مرتجعات المورّدين في eplus"
Say " الفرع: $Branch  |  السيرفر: $($b.server)  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Say "=========================================================="

# ── ١) أعمدة جداول فاتورة الشراء بالكامل ─────────────────────────
#    المزامنة بتسحب أعمدة مختارة، فيمكن يكون فيه عمود تاريخ مرتجع مش واصلنا.
Q @"
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
  FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_NAME = 'pur_trans_d'
 ORDER BY ORDINAL_POSITION
"@ "١/أ — كل أعمدة pur_trans_d (بنود فاتورة الشراء)"

Q @"
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
  FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_NAME = 'pur_trans_h'
 ORDER BY ORDINAL_POSITION
"@ "١/ب — كل أعمدة pur_trans_h (رأس فاتورة الشراء)"

# ── ٢) أعمدة مستند المرتجع — للمقارنة ────────────────────────────
Q @"
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
  FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_NAME IN ('Item_back_h','Item_back_d')
 ORDER BY TABLE_NAME, ORDINAL_POSITION
"@ "٢ — أعمدة مستند المرتجع Item_back_h/d"

# ── ٣) أي جدول شكله لوج ──────────────────────────────────────────
Q @"
SELECT TABLE_NAME
  FROM INFORMATION_SCHEMA.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE'
   AND (TABLE_NAME LIKE '%log%'   OR TABLE_NAME LIKE '%audit%'
     OR TABLE_NAME LIKE '%hist%'  OR TABLE_NAME LIKE '%trace%'
     OR TABLE_NAME LIKE '%track%' OR TABLE_NAME LIKE '%sec_%')
 ORDER BY TABLE_NAME
"@ "٣ — جداول اسمها فيه log/audit/hist/trace/track/sec_"

# ── ٤) أي جدول بيشاور على فاتورة شراء ────────────────────────────
#    لو فيه لوج للتعديلات، غالبًا هيبقى فيه عمود pth_id أو ptd_id.
Q @"
SELECT TABLE_NAME, COLUMN_NAME
  FROM INFORMATION_SCHEMA.COLUMNS
 WHERE (COLUMN_NAME LIKE '%pth%' OR COLUMN_NAME LIKE '%ptd%')
   AND TABLE_NAME NOT IN ('pur_trans_h','pur_trans_d')
 ORDER BY TABLE_NAME, COLUMN_NAME
"@ "٤ — جداول تانية فيها عمود pth/ptd (مرجع لفاتورة الشراء)"

# ── ٥) تريجرات على جداول الشراء ──────────────────────────────────
#    لو فيه تريجر بيكتب لوج، هنلاقي الجدول الهدف من اسمه.
Q @"
SELECT o.name AS trigger_name, OBJECT_NAME(o.parent_obj) AS on_table
  FROM sysobjects o
 WHERE o.xtype = 'TR'
   AND OBJECT_NAME(o.parent_obj) IN ('pur_trans_h','pur_trans_d','Item_back_h','Item_back_d')
"@ "٥ — تريجرات على جداول الشراء والمرتجع"

# ── ٦) أسماء المستخدمين اللي ظهروا في sec_update_uid ─────────────
Q @"
SELECT e_id, e_Name FROM Employee WHERE e_id IN (60, 239, 334) ORDER BY e_id
"@ "٦ — ترجمة أرقام المستخدمين (من sec_update_uid)"

# ── ٧) عيّنة: فاتورة فيها مرتجع — كل أعمدة السطر زي ما هي ────────
#    لو فيه عمود تاريخ على السطر، هيبان هنا بقيمة فيه.
Q @"
SELECT TOP 3 d.*
  FROM pur_trans_d d
 WHERE d.itm_back_qty IS NOT NULL AND d.itm_back_qty <> 0
 ORDER BY d.pth_id DESC
"@ "٧ — عيّنة صفوف فيها مرتجع (كل الأعمدة بقيمها)"

$cn.Close()

Say ""
Say "=========================================================="
Say " خلص. الناتج اتحفظ في: $Out"
Say "=========================================================="
Set-Content -Path $Out -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
