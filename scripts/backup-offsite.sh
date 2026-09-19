#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  رفع النسخة الاحتياطية برّه السيرفر (مشفّرة) على Google Drive
# ═══════════════════════════════════════════════════════════════════
#  نسخة على نفس القرص بتحميك من: migration غلط · حذف بالغلط · جدول باظ.
#  **مابتحميكش من:** القرص يفصل · الحساب يتقفل · السيرفر يتخرق.
#  السكربت ده بيقفل الفجوة دي.
#
#  ═══ التشفير — اقرا ده كويس ═══
#  النسخة فيها `.env` (ختم التوكنات وكلمة سر القاعدة) وبيانات العملاء
#  (أسماء وتليفونات وعناوين). رفعها زي ما هي = أي حد يوصل لحساب جوجل
#  ياخد النظام كله. فبنشفّرها بـAES-256 قبل الرفع.
#
#  🔑 كلمة السر في /root/.phalix-offsite-pass (600) — **ولازم تكون
#     محفوظة كمان في مدير كلمات السر بتاع المالك**. لو السيرفر ضاع
#     وكلمة السر كانت عليه بس، النسخة المرفوعة بتبقى ملف مالوش لازمة.
#     ده مش تحذير شكلي — ده الفرق بين نسخة تنفع ونسخة تتفرج عليها.
#
#  الاستعمال:
#     ./backup-offsite.sh            # يرفع آخر نسخة
#     ./backup-offsite.sh -q         # للكرون
#     ./backup-offsite.sh --check    # يعرض اللي مرفوع وآخر رفعة
#     ./backup-offsite.sh --restore-help   # إزاي أفك التشفير
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

DIR="${PHALIX_BACKUP_DIR:-/root/backups}"
REMOTE="${PHALIX_REMOTE:-gdrive:phalix-backups}"
PASSFILE="${PHALIX_PASSFILE:-/root/.phalix-offsite-pass}"
KEEP="${PHALIX_REMOTE_KEEP:-14}"     # كام نسخة نسيبها هناك
RCLONE="${PHALIX_RCLONE:-rclone}"
QUIET=0; CHECK=0; NOTABLE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet)      QUIET=1 ;;
    --check)         CHECK=1 ;;
    --restore-help)
      cat <<'HELP'
فك التشفير والرجوع من نسخة مرفوعة:

  1) نزّل النسخة من Drive (على السيرفر أو أي جهاز فيه rclone):
     rclone copy gdrive:phalix-backups/20260919-0300.tar.gz.enc .

  2) فك التشفير (هيسألك كلمة السر):
     openssl enc -d -aes-256-cbc -pbkdf2 -in 20260919-0300.tar.gz.enc | tar -xzf -

  3) بعدها اتبع docs/server_backup_restore.md

⚠️ من غير كلمة السر الملف ده مالوش أي فايدة. لو مش لاقيها، مفيش طريقة
   تانية — مفيش باب خلفي ومفيش استرجاع.
HELP
      exit 0 ;;
    -h|--help)       sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "خيار مش معروف: $1" >&2; exit 2 ;;
  esac
  shift
done

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
  echo "النسخ المرفوعة (الأحدث آخر سطر):"
  $RCLONE lsl "$REMOTE" 2>/dev/null | sort -k4 | tail -20 || echo "  مفيش — الربط مش شغّال؟"
  echo
  echo "إجمالي المساحة المستعملة:"
  $RCLONE size "$REMOTE" 2>/dev/null || true
  exit 0
fi

[ -s "$PASSFILE" ] || { echo "✗ ملف كلمة السر مش موجود أو فاضي: $PASSFILE"; exit 1; }
[ "$(stat -c %a "$PASSFILE")" = "600" ] || echo "⚠️ صلاحيات $PASSFILE مش 600"

# آخر نسخة محلية
LAST="$(ls -1d "$DIR"/2* 2>/dev/null | tail -1)"
[ -n "$LAST" ] || { echo "✗ مفيش نسخ محلية في $DIR — شغّل server-backup.sh الأول"; exit 1; }
NAME="$(basename "$LAST")"

# اتأكد إنها سليمة قبل ما نرفع — رفع نسخة تالفة أسوأ من مفيش
[ -s "$LAST/db.dump" ] || { echo "✗ $NAME: db.dump ناقص"; exit 1; }
[ "$(head -c 5 "$LAST/db.dump")" = "PGDMP" ] || { echo "✗ $NAME: db.dump مش ملف نسخة"; exit 1; }

# مرفوعة قبل كده؟
if $RCLONE lsf "$REMOTE/$NAME.tar.gz.enc" >/dev/null 2>&1; then
  echo "✓ $NAME مرفوعة خلاص"
else
  echo "── رفع $NAME ──"
  TMPENC="$(mktemp /tmp/phalix-XXXX.enc)"
  # نضغط ونشفّر في خط واحد — مفيش نسخة غير مشفّرة بتتكتب على القرص
  tar -czf - -C "$DIR" "$NAME" \
    | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$PASSFILE" -out "$TMPENC"
  sz=$(( $(stat -c %s "$TMPENC") / 1048576 ))
  [ "$sz" -ge 1 ] || { echo "✗ الملف المشفّر ${sz}MB — حاجة غلط"; exit 1; }
  $RCLONE copyto "$TMPENC" "$REMOTE/$NAME.tar.gz.enc" --no-traverse
  echo "  ✓ اترفع — ${sz}MB"
fi

# ── تنظيف القديم من Drive ──────────────────────────────────────────
n="$($RCLONE lsf "$REMOTE" 2>/dev/null | grep -c '\.enc$' || true)"
if [ "${n:-0}" -gt "$KEEP" ]; then
  for f in $($RCLONE lsf "$REMOTE" 2>/dev/null | grep '\.enc$' | sort | head -n $(( n - KEEP ))); do
    $RCLONE deletefile "$REMOTE/$f" && echo "  اتمسح القديم: $f"
  done
fi

echo "✓ تمام — $($RCLONE lsf "$REMOTE" 2>/dev/null | grep -c '\.enc$') نسخة برّه السيرفر"
