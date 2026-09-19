#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  المزامنة اليومية: السيرفر الذاتي يتحدّث من السحابة
# ═══════════════════════════════════════════════════════════════════
#  السحابة هي مصدر الحقيقة لحد يوم التحويل. السكربت ده بيخلّي بيانات
#  السيرفر قريبة منها دايمًا، عشان (١) التجربة تبقى على أرقام حقيقية
#  و(٢) التحويل في أي لحظة يبقى مزامنة ساعة مش ١٣ يوم.
#
#  الاستعمال:
#     ./sync-from-cloud.sh           # اليومي (آخر 3 أيام)
#     ./sync-from-cloud.sh --days 7  # لو فات كام يوم
#     ./sync-from-cloud.sh --full    # كامل: بيفضّي ويجيب من الأول (بطيء)
#     ./sync-from-cloud.sh -q        # للكرون: ساكت إلا لو مشكلة
#
#  ⚠️ لو الكرون فضل ساكت أسابيع، ده مش دليل إنه شغّال — استعمل
#     --check عشان تشوف آخر مزامنة نجحت إمتى.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="${PHALIX_REPO_DIR:-/root/phalix-repo}"
COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
DOCKER="${PHALIX_DOCKER:-docker}"
MODE=delta; DAYS=3; QUIET=0; CHECK=0; NOTABLE=0; AUTH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --full)    MODE=full ;;
    --days)    DAYS="${2:-3}"; shift ;;
    --check)   CHECK=1 ;;
    --no-auth) AUTH=0 ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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
  if [ "$QUIET" = 1 ]; then
    [ "$NOTABLE" = 1 ] && cat "$LOGTMP" >&3
    rm -f "$LOGTMP"
  fi
}
trap finish EXIT

cd "$COMPOSE_DIR" 2>/dev/null || { echo "✗ مجلد سوبابيز مش موجود"; exit 1; }
CID="$($DOCKER compose ps -q db 2>/dev/null | head -1)"
[ -n "$CID" ] || CID="$($DOCKER inspect -f '{{.Id}}' supabase-db 2>/dev/null || true)"
[ -n "$CID" ] || { echo "✗ حاوية القاعدة مش لاقيها"; exit 1; }

psql_q() { $DOCKER exec -i "$CID" psql -U "$DB_USER" -d postgres -tAc "$1"; }

# ── فحص: آخر مزامنة نجحت إمتى ──────────────────────────────────────
if [ "$CHECK" = 1 ]; then
  echo "آخر مزامنة:"
  psql_q "select '  ' || to_char(max(ran_at) at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI')
                || '  ·  ' || mode || '  ·  ' || count(*) || ' جدول'
          from public.cloud_sync_log
          where ran_at > (select max(ran_at) from public.cloud_sync_log) - interval '1 hour'
          group by mode" 2>/dev/null || echo "  مفيش سجل — المزامنة ماشتغلتش ولا مرة"
  echo "آخر 5 مشاكل:"
  psql_q "select '  ' || to_char(ran_at at time zone 'Africa/Cairo','MM-DD HH24:MI') || '  ' || tbl || ': ' || left(detail,60)
          from public.cloud_sync_log where status <> 'ok' order by ran_at desc limit 5" 2>/dev/null
  exit 0
fi

# الريبو الأول — السكربت بيقرا ملف SQL منه
git -C "$REPO" pull --ff-only --quiet 2>/dev/null || echo "⚠️ git pull فشل — هنشتغل بالنسخة الموجودة"

SQL="$REPO/docs/refresh_data_from_cloud.sql"
[ -f "$SQL" ] || { echo "✗ ملف المزامنة مش موجود: $SQL"; exit 1; }

echo "── مزامنة ($MODE${MODE:+, }${DAYS} يوم) $(date '+%Y-%m-%d %H:%M') ──"
$DOCKER exec -i "$CID" psql -U "$DB_USER" -d postgres \
  -v ON_ERROR_STOP=1 -v mode="$MODE" -v days="$DAYS" < "$SQL"

# حسابات الدخول: قليلة العدد بس الدور فيها بيتغيّر، والصلاحيات كلها
# معتمدة على الدور — فلازم تتزامن كل يوم مع البيانات
AUTH_SQL="$REPO/docs/refresh_auth_users.sql"
if [ "$AUTH" = 1 ] && [ -f "$AUTH_SQL" ]; then
  echo "── حسابات الدخول ──"
  $DOCKER exec -i "$CID" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -q < "$AUTH_SQL"     || { NOTABLE=1; echo "⚠️ مزامنة الحسابات فشلت"; }
fi

# حارس الانحراف: بيقارن سكيما السيرفر بالسحابة كل يوم. الانحراف
# بيحصل لما حد يعدّل على السحابة مباشرة — واكتشفناه أول مرة بالصدفة.
DRIFT_SQL="$REPO/docs/schema_drift_watch.sql"
if [ -f "$DRIFT_SQL" ]; then
  drift="$($DOCKER exec -i "$CID" psql -U "$DB_USER" -d postgres -q < "$DRIFT_SQL" 2>&1 || true)"
  if printf %s "$drift" | grep -q "⚠️"; then
    NOTABLE=1
    echo "── انحراف عن السحابة ──"
    printf %s\n "$drift"
  fi
fi

# فشل جدول واحد مابيوقّفش السكربت (بيتسجّل في اللوج) — بس لازم نتكلم عنه
fails="$(psql_q "select count(*) from public.cloud_sync_log
                 where ran_at > now() - interval '2 hours' and status <> 'ok'" | tr -d ' ')"
if [ "${fails:-0}" != "0" ]; then
  NOTABLE=1
  echo "⚠️ $fails جدول فشلوا — شوف: $0 --check"
  exit 1
fi
echo "✓ تمام"
