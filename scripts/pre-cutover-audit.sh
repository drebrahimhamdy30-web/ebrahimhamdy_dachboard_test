#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  مسح شامل قبل التحويل — وبيحفظ تقرير تقدر ترجعله
# ═══════════════════════════════════════════════════════════════════
#  بيشغّل docs/pre_cutover_audit.sql ويحفظ الخرج في ملف، ويطبع
#  الملخص والحكم على الشاشة.
#
#  ليه بيحفظ ملف: التقرير بيطلع طويل (مئات السطور لو الانحراف كبير)،
#  والـterminal بياكل أوله. وكمان عايزين نقدر نقارن قبل وبعد
#  الاستلحاق — «كان ٨٤ وبقى ٣» معلومة، و«فيه ٣» لوحدها لأ.
#
#  🔒 قراءة بس — مابيعدّلش أي قاعدة.
#
#  الاستعمال (على السيرفر):
#     ./scripts/pre-cutover-audit.sh
#     ./scripts/pre-cutover-audit.sh --full    # يطبع التقرير كامل كمان
#
#  كود الخروج: 0 لو مفيش فرق · 1 لو فيه · 2 لو المسح نفسه فشل.
#  الفرق بين 1 و2 مهم: الأول «قِست ولقيت فرق»، والتاني «مقدرتش أقيس»
#  — وده **مش** نفس معنى «مفيش فرق».
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

REPO="${PHALIX_REPO:-/root/phalix-repo}"
COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
OUT_DIR="${PHALIX_AUDIT_DIR:-/root}"
FULL=0
[ "${1:-}" = "--full" ] && FULL=1

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else G=''; Y=''; R=''; B=''; N=''; fi

SQL="$REPO/docs/pre_cutover_audit.sql"
[ -f "$SQL" ] || { echo "${R}✗ مش لاقي $SQL — اعمل git pull${N}"; exit 2; }

cd "$COMPOSE_DIR" 2>/dev/null || { echo "${R}✗ مجلد سوبابيز مش موجود${N}"; exit 2; }
CID="$(docker compose ps -q db 2>/dev/null | head -1)"
[ -n "$CID" ] || { echo "${R}✗ حاوية القاعدة مش لاقيها${N}"; exit 2; }

STAMP="$(date +%Y%m%d_%H%M)"
REPORT="$OUT_DIR/pre_cutover_audit_$STAMP.txt"

printf '%s── المسح شغّال (بيقارن بالمحتوى — ياخد شوية) ──%s\n' "$B" "$N"
docker exec -i "$CID" psql -U "$DB_USER" -d postgres < "$SQL" > "$REPORT" 2>&1
rc=$?

if [ "$rc" != 0 ] || grep -qE '^(ERROR|psql:.*ERROR|FATAL)' "$REPORT"; then
  printf '\n%s%s🔴 المسح نفسه فشل — مانعرفش الحالة.%s\n' "$R" "$B" "$N"
  grep -E '^(ERROR|psql:.*ERROR|FATAL|NOTICE)' "$REPORT" | head -8 | sed 's/^/   /'
  echo "   التقرير: $REPORT"
  echo "   ${Y}«مقدرتش أقيس» مش معناها «مفيش فرق» — ماتحوّلش على الأساس ده.${N}"
  exit 2
fi

if [ "$FULL" = 1 ]; then
  cat "$REPORT"
else
  # الملخص والحكم بس — الباقي في الملف
  sed -n '/١) الملخص/,/٢) 🔴 ناقص/p' "$REPORT" | sed '$d'
  printf '\n'
  sed -n '/٦) العزل/,$p' "$REPORT"
fi

printf '\n📄 التقرير كامل: %s%s%s\n' "$B" "$REPORT" "$N"
prev="$(ls -1t "$OUT_DIR"/pre_cutover_audit_*.txt 2>/dev/null | sed -n '2p')"
[ -n "$prev" ] && echo "   السابق للمقارنة: $prev"

if grep -q 'جاهز للتحويل' "$REPORT"; then
  printf '\n%s%s✓ السيرفر يساوي السحابة بالمحتوى.%s\n' "$G" "$B" "$N"
  exit 0
fi

n="$(grep -oE '⚠️ [0-9]+ فرق' "$REPORT" | grep -oE '[0-9]+' | head -1)"
printf '\n%s⚠️ فيه %s فرق.%s الإصلاح: %s./scripts/catchup.sh --apply%s ثم شغّل المسح تاني.\n' \
  "$Y" "${n:-?}" "$N" "$B" "$N"
printf '   واللي الاستلحاق مابيعملوش بيظهر في خرجه كـ«محتاج قرار بشري».\n'
exit 1
