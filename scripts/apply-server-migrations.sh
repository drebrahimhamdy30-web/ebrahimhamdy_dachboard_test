#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  تطبيق الـmigrations الناقصة على قاعدة السيرفر الذاتي
# ═══════════════════════════════════════════════════════════════════
#  الترتيب مهم: migrate_21 بيضيف أعمدة التحضير، و migrate_27 بيستعملها.
#
#  بيقف عند أول خطأ (ON_ERROR_STOP) — مايكملش وسايب القاعدة في النص.
#  كل ملف بيتشغّل لوحده، فلو وقع تعرف بالظبط عند أنهي ملف.
#
#  الاستعمال:
#     ./apply-server-migrations.sh -n     # تجربة: يقول هيشغّل إيه
#     ./apply-server-migrations.sh        # التطبيق (بيسأل قبلها)
#
#  ⚠️ خد نسخة احتياطية الأول:  ./server-backup.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="${PHALIX_REPO_DIR:-/root/phalix-repo}"
COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
DRY=0

# الترتيب ده مقصود — الاعتماديات بينهم
FILES="
migrate_10_supplier_collections
migrate_12_supplier_collection_returns
migrate_13_supplier_balance_notes
migrate_14_contract_return_status
migrate_16_freeze_contract_invoice_value
migrate_16_sales_items_branch_key
migrate_17_contract_merge_rpc
migrate_18_jard_expiry
migrate_19_submit_jard_audit
migrate_20_bank_transactions
migrate_21_prep_report
migrate_22_tab_permissions
migrate_23_tasks_excluded_branches
migrate_24_jard_committee_checkin
migrate_25_kpi_dashboard
migrate_26_min_stock_alerts
integration_branch_stores
migrate_27_server_catchup
"

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "خيار مش معروف: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=''; G=''; Y=''; R=''; N=''; fi

cd "$COMPOSE_DIR" 2>/dev/null || { echo "${R}✗ مجلد سوبابيز مش موجود${N}"; exit 1; }
CID="$(docker compose ps -q db 2>/dev/null | head -1)"
[ -n "$CID" ] || CID="$(docker inspect -f '{{.Id}}' supabase-db 2>/dev/null || true)"
[ -n "$CID" ] || { echo "${R}✗ حاوية القاعدة مش لاقيها${N}"; exit 1; }

# فحص وجود الملفات قبل ما نبدأ — أحسن من إننا نقع في النص
missing=0
for f in $FILES; do
  [ -f "$REPO/docs/$f.sql" ] || { echo "${R}✗ ناقص: docs/$f.sql${N}"; missing=1; }
done
[ "$missing" = 0 ] || { echo "اعمل git pull في $REPO الأول"; exit 1; }

n=$(printf '%s\n' $FILES | wc -l)
echo "${B}$n ملف هيتشغّلوا بالترتيب على قاعدة السيرفر${N}"
if [ "$DRY" = 1 ]; then
  i=0
  for f in $FILES; do i=$((i+1)); printf '  %2s) %s\n' "$i" "$f"; done
  echo "${Y}(تجربة — مفيش حاجة اتنفّذت)${N}"
  exit 0
fi

echo "${Y}⚠️ ده بيعدّل قاعدة السيرفر. خدت نسخة احتياطية؟${N}"
printf "نكمل؟ (y/N) "
read -r REPLY
case "$REPLY" in [Yy]) ;; *) echo "اتلغى."; exit 0 ;; esac

i=0; ok=0
for f in $FILES; do
  i=$((i+1))
  printf '\n%s[%s/%s] %s%s\n' "$B" "$i" "$n" "$f" "$N"
  if docker exec -i "$CID" psql -U "$DB_USER" -d postgres \
       -v ON_ERROR_STOP=1 -q < "$REPO/docs/$f.sql"; then
    ok=$((ok+1)); printf '  %s✓ تمام%s\n' "$G" "$N"
  else
    printf '  %s✗ وقع هنا — القاعدة اتسابت عند الملف ده%s\n' "$R" "$N"
    printf '  اللي نجح قبله: %s ملف. ابعت الرسالة اللي فوق.\n' "$ok"
    exit 1
  fi
done

printf '\n%s✓ خلص — %s ملف اتطبّقوا%s\n' "$G" "$ok" "$N"
printf '\nالخطوة الجاية: قارن تاني عشان تتأكد إن الفرق قفل:\n'
printf '  docker exec -i %s psql -U %s -d postgres < %s/docs/schema_diff_vs_prod.sql\n' \
  "${CID:0:12}" "$DB_USER" "$REPO"
printf '\nوبعدها خلّي PostgREST يقرا السكيما الجديدة:\n'
printf "  docker exec -i %s psql -U %s -d postgres -c \"NOTIFY pgrst,'reload schema'\"\n" \
  "${CID:0:12}" "$DB_USER"
