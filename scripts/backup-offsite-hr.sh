#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  رفع نسخة HR الاحتياطية برّه السيرفر (مشفّرة) على Google Drive
# ═══════════════════════════════════════════════════════════════════
#  نظام HR بياخد نسخة كل 6 ساعات في /home/HR/backend/backups — **كلها
#  على نفس القرص**. ودي بتحميك من: ترحيل غلط · حذف بالغلط · جدول باظ.
#  **مابتحميكش من:** القرص يفصل · السيرفر يتخرق · الحساب يتقفل.
#  اتكشف 2026-11-27 إن مفيش ولا نسخة HR واحدة برّه السيرفر — السكربت
#  ده بيقفل الفجوة دي. (الشقيق backup-offsite.sh كان لسوبابيز الذاتي
#  اللي اتحذف، وشكل نسخه مختلف: مجلدات مش ملف واحد.)
#
#  ═══ التشفير — اقرا ده كويس ═══
#  نسخة HR فيها **أرقام قومية ومرتبات وتليفونات وعناوين موظفين**.
#  رفعها زي ما هي = أي حد يوصل لحساب جوجل ياخد ملفات الموظفين كلها.
#  فبنشفّرها بـAES-256 قبل ما تسيب السيرفر.
#
#  🔑 كلمة السر في /root/.phalix-offsite-pass (600) — **ولازم تكون
#     محفوظة كمان في مدير كلمات السر بتاع المالك**. لو السيرفر ضاع
#     وكلمة السر كانت عليه بس، النسخة المرفوعة بتبقى ملف مالوش لازمة.
#     ده مش تحذير شكلي — ده الفرق بين نسخة تنفع ونسخة تتفرج عليها.
#
#  الاستعمال:
#     ./backup-offsite-hr.sh            # يرفع أحدث نسخة
#     ./backup-offsite-hr.sh -q         # للكرون
#     ./backup-offsite-hr.sh --check    # يعرض اللي مرفوع والمساحة
#     ./backup-offsite-hr.sh --restore-help   # إزاي أرجع من نسخة
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

DIR="${HR_BACKUP_DIR:-/home/HR/backend/backups}"
REMOTE="${HR_REMOTE:-gdrive:hr-backups}"
PASSFILE="${HR_PASSFILE:-/root/.phalix-offsite-pass}"
KEEP="${HR_REMOTE_KEEP:-14}"       # كام نسخة نسيبها على Drive
RCLONE="${HR_RCLONE:-rclone}"
QUIET=0; CHECK=0; NOTABLE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet)      QUIET=1 ;;
    --check)         CHECK=1 ;;
    --restore-help)
      cat <<'HELP'
الرجوع من نسخة HR مرفوعة:

  1) نزّل النسخة (على السيرفر أو أي جهاز فيه rclone):
     rclone copy gdrive:hr-backups/backup_2026-11-27-13-49-09.sql.gz.enc .

  2) فك التشفير:
     openssl enc -d -aes-256-cbc -pbkdf2 \
       -in backup_2026-11-27-13-49-09.sql.gz.enc \
       -out hr.sql.gz

  3) اتأكد إنها سليمة قبل ما تلمس أي قاعدة:
     gunzip -c hr.sql.gz | tail -3
     (لازم تشوف: PostgreSQL database dump complete)

  4) الاسترجاع في قاعدة **جديدة** الأول — ماتكتبش فوق الشغّالة:
     createdb hr_restore -O hr
     gunzip -c hr.sql.gz | sed 's/^\\restrict.*$/-- restrict removed/' \
       | psql -d hr_restore

  ⚠️ معروف: الفيو الماديّة purchaseCatalogSearch بترجع **فاضية** لأن
     first_word بتنادي ar_norm من غير public. قدامها والـdump بيشتغل
     بـsearch_path فاضي. بعد الاسترجاع:
     psql -d hr_restore -c 'REFRESH MATERIALIZED VIEW public."purchaseCatalogSearch";'

⚠️ من غير كلمة السر الملف ده مالوش أي فايدة. مفيش باب خلفي ومفيش استرجاع.
HELP
      exit 0 ;;
    -h|--help)       sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "خيار مش معروف: $1" >&2; exit 2 ;;
  esac
  shift
done

# في الوضع الصامت مابنطبعش غير لو حصل حاجة تستاهل — عشان الكرون
# مايبعتش إيميل كل يوم ومايخلّيش السجل يكبر على الفاضي.
if [ "$QUIET" = 1 ]; then
  LOGTMP="$(mktemp)"; exec 3>&1; exec >"$LOGTMP" 2>&1
fi
finish() {
  rc=$?
  [ "$rc" != 0 ] && NOTABLE=1
  [ -n "${TMPENC:-}" ] && rm -f "$TMPENC"
  if [ "$QUIET" = 1 ]; then
    [ "$NOTABLE" = 1 ] && cat "$LOGTMP" >&3
    rm -f "$LOGTMP"
  fi
}
trap finish EXIT

command -v "$RCLONE" >/dev/null || { echo "✗ rclone مش متركّب"; exit 1; }

# ── فحص: إيه المرفوع؟ ──────────────────────────────────────────────
if [ "$CHECK" = 1 ]; then
  echo "نسخ HR المرفوعة (الأحدث آخر سطر):"
  $RCLONE lsl "$REMOTE" 2>/dev/null | sort -k4 | tail -20 || echo "  مفيش — الربط مش شغّال؟"
  echo
  echo "إجمالي المساحة المستعملة:"
  $RCLONE size "$REMOTE" 2>/dev/null || true
  exit 0
fi

[ -s "$PASSFILE" ] || { echo "✗ ملف كلمة السر مش موجود أو فاضي: $PASSFILE"; exit 1; }
[ "$(stat -c %a "$PASSFILE")" = "600" ] || echo "⚠️ صلاحيات $PASSFILE مش 600"

# أحدث نسخة مضغوطة. الاسم فيه ختم زمني مصفوف بأصفار
# (backup_2026-11-27-13-49-09.sql.gz) فالترتيب الأبجدي = الترتيب الزمني.
LAST="$(ls -1 "$DIR"/backup_*.sql.gz 2>/dev/null | sort | tail -1)"
[ -n "$LAST" ] || { echo "✗ مفيش نسخة مضغوطة في $DIR — النظام لسه بيكتب .sql خام؟"; exit 1; }
NAME="$(basename "$LAST")"

# مرفوعة قبل كده؟ نسأل الأول عشان مانفكّش 183 ميجا على الفاضي.
if $RCLONE lsf "$REMOTE/$NAME.enc" >/dev/null 2>&1; then
  echo "✓ $NAME مرفوعة خلاص"
  exit 0
fi

# ── التحقق قبل الرفع — رفع نسخة تالفة أسوأ من مفيش ────────────────
# الفحص ده بيفك الأرشيف **كله** (فبيكشف أي تلف) وبيتأكد إن آخر سطر هو
# ختم pg_dump (فبيكشف النسخة الناقصة). فحص الحجم أو أول بايتات
# مابيكشفش dump اتقطع في النص.
echo "── فحص $NAME ──"
if ! gunzip -c "$LAST" | tail -5 | grep -q 'PostgreSQL database dump complete'; then
  echo "✗ $NAME: الأرشيف تالف أو النسخة ناقصة — مش هيترفع"
  exit 1
fi
echo "  ✓ سليمة وكاملة"

# ── التشفير والرفع ────────────────────────────────────────────────
# الملف مضغوط أصلًا (gzip) فبنشفّره على طول — مفيش tar ولا ضغط تاني.
echo "── رفع $NAME ──"
TMPENC="$(mktemp /tmp/hr-offsite-XXXX.enc)"
openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$PASSFILE" -in "$LAST" -out "$TMPENC"

sz=$(( $(stat -c %s "$TMPENC") / 1048576 ))
[ "$sz" -ge 1 ] || { echo "✗ الملف المشفّر ${sz}MB — حاجة غلط"; exit 1; }

$RCLONE copyto "$TMPENC" "$REMOTE/$NAME.enc" --no-traverse
echo "  ✓ اترفع — ${sz}MB"
NOTABLE=0

# ── تنظيف القديم من Drive ──────────────────────────────────────────
n="$($RCLONE lsf "$REMOTE" 2>/dev/null | grep -c '\.enc$' || true)"
if [ "${n:-0}" -gt "$KEEP" ]; then
  for f in $($RCLONE lsf "$REMOTE" 2>/dev/null | grep '\.enc$' | sort | head -n $(( n - KEEP ))); do
    $RCLONE deletefile "$REMOTE/$f" && echo "  اتمسح القديم: $f"
  done
fi
