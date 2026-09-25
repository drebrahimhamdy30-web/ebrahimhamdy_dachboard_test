#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  تحويل الرابط والمفتاح المكتوبين في كود عقد n8n لمتغيّرات بيئة
# ═══════════════════════════════════════════════════════════════════
#  ليه: «sync customers balances -> supabase» فيها ٤ عقد Code — فرع
#  لكل واحدة — والرابط والمفتاح مكتوبين بالإيد جوّه الكود. مفيش
#  كريدنشيال، يعني تعديل الكريدنشيالات يوم التحويل **مش هيلمسها**.
#  ولو اتنست واحدة بس، فرع واحد يفضل يكتب أرصدته في السحابة
#  المتجمّدة — خطأ جزئي وصامت، وده أصعب شكل تكتشفه.
#
#  بعد التحويل ده: يوم التحويل = متغيّرين + إعادة تشغيل n8n. خلاص.
#
#  ⚠️ بيعدّل ورك فلوز شغّالة في الإنتاج. عشان كده:
#     • بياخد نسخة كاملة الأول ويقول لك أمر الرجوع
#     • بيوريك هيغيّر إيه ويقف (لازم --apply عشان يكتب)
#     • بيرفض يكمّل لو فضل أي أثر للسحابة بعد التحويل
#     • بيتأكد إن الورك فلو فضل Active بعد الاستيراد
#
#  🔒 مافيش أي كود ولا أي سر بيتطبع — أعداد بس.
#
#  الاستعمال (من السيرفر):
#     ./scripts/n8n-envify.sh                # فحص + معاينة
#     ./scripts/n8n-envify.sh --apply        # ينفّذ
#     ./scripts/n8n-envify.sh --wf "اسم"     # ورك فلو تاني
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APPLY=0
WF="sync customers balances"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --wf)    WF="${2:-}"; shift ;;
    *) sed -n '2,30p' "$0"; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else G=''; Y=''; R=''; B=''; N=''; fi

C="${N8N_CONTAINER:-$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i n8n | head -1)}"
[ -n "$C" ] || { echo "${R}✗ مالقيتش حاوية n8n${N}"; exit 1; }
echo "${B}حاوية n8n:${N} $C"

# ── ١) $env شغّال جوّه العقد أصلًا؟ ─────────────────────────────────
# لو متغيّر الحظر مضبوط true، الكود بعد التحويل هيقع وقت التشغيل —
# ومش وقت الاستيراد. يعني هنكتشفها بعد ساعة لما المزامنة تفشل.
BLOCK="$(docker exec "$C" printenv N8N_BLOCK_ENV_ACCESS_IN_NODE 2>/dev/null | tr -d '\r')"
printf '  وصول $env جوّه العقد: '
case "${BLOCK,,}" in
  true|1) echo "${R}محظور${N}"
          echo "  ${Y}N8N_BLOCK_ENV_ACCESS_IN_NODE=true — شيله أو خلّيه false${N}"
          echo "  في docker-compose بتاع n8n، وبعدها: docker compose up -d n8n"
          exit 1 ;;
  *)      echo "${G}مسموح${N}${BLOCK:+ (=$BLOCK)}" ;;
esac

# ── ٢) المتغيّرين موجودين؟ ─────────────────────────────────────────
MISS=0
for v in SUPABASE_URL SUPABASE_SERVICE_KEY; do
  val="$(docker exec "$C" printenv "$v" 2>/dev/null | tr -d '\r')"
  if [ -z "$val" ]; then
    printf "  %-22s ${R}ناقص${N}\n" "$v"
    MISS=1
  else
    # الطول بس — القيمة عمرها ماتتطبع
    printf '  %-22s %s✓%s (%s حرف)\n' "$v" "$G" "$N" "${#val}"
  fi
done

if [ "$MISS" = 1 ]; then
  cat <<EOF

${Y}${B}حطّ المتغيّرين الأول — بقيم السحابة دلوقتي${N}

في docker-compose بتاع n8n تحت ${B}environment${N}:

    - SUPABASE_URL=https://rxtjoqulmgkkcohmgzgi.supabase.co
    - SUPABASE_SERVICE_KEY=<مفتاح service_role بتاع السحابة>

وبعدها:  ${B}docker compose up -d n8n${N}

${B}ليه قيم السحابة مش السيرفر؟${N} عشان السلوك مايتغيّرش النهاردة
خالص — الكود يقرا نفس القيم اللي كان بيستعملها. التحويل الحقيقي
بيبقى سطرين في نفس الملف يوم التحويل.

EOF
  exit 1
fi

# ── ٣) نسخة كاملة قبل أي حاجة ──────────────────────────────────────
STAMP="$(date +%Y%m%d_%H%M%S)"
BK="/tmp/n8n_backup_$STAMP.json"
printf '\n  بآخد نسخة كاملة... '
docker exec -u node "$C" n8n export:workflow --all --output="$BK" >/dev/null 2>&1 \
  || docker exec "$C" n8n export:workflow --all --output="$BK" >/dev/null 2>&1 \
  || { echo "${R}فشل${N}"; exit 1; }
docker cp "$C:$BK" "/root/n8n_backup_$STAMP.json" >/dev/null 2>&1
echo "${G}تمام${N}  → /root/n8n_backup_$STAMP.json"

# ── ٤) التحويل (معاينة) ────────────────────────────────────────────
OUT="/tmp/n8n_envified_$STAMP.json"
docker cp "$HERE/n8n-envify.js" "$C:/tmp/n8n-envify.js" >/dev/null 2>&1 || {
  echo "${R}✗ مقدرتش أنقل ملف التحويل${N}"; exit 1; }
docker exec "$C" node /tmp/n8n-envify.js "$BK" "$OUT" "$WF"
rc=$?
if [ "$rc" != 0 ]; then
  docker exec "$C" rm -f "$OUT" /tmp/n8n-envify.js >/dev/null 2>&1
  exit $rc
fi

if [ "$APPLY" != 1 ]; then
  cat <<EOF

${Y}(معاينة — مفيش حاجة اتغيّرت في n8n)${N}
للتنفيذ:  ${B}$0 --apply${N}
EOF
  docker exec "$C" rm -f "$OUT" /tmp/n8n-envify.js >/dev/null 2>&1
  exit 0
fi

# ── ٥) التنفيذ ─────────────────────────────────────────────────────
printf "\n${B}ده بيعدّل ورك فلو شغّال في الإنتاج. اكتب %sتنفيذ%s: " "$B" "$N"
read -r a
[ "$a" = "تنفيذ" ] || { echo "اتلغى."
  docker exec "$C" rm -f "$OUT" /tmp/n8n-envify.js >/dev/null 2>&1; exit 0; }

printf '  بستورد... '
if docker exec -u node "$C" n8n import:workflow --input="$OUT" >/dev/null 2>&1 \
   || docker exec "$C" n8n import:workflow --input="$OUT" >/dev/null 2>&1; then
  echo "${G}تمام${N}"
else
  echo "${R}فشل${N}"
  echo "  ${Y}مفيش حاجة اتغيّرت غالبًا، بس اتأكد من الواجهة.${N}"
  echo "  الرجوع: docker exec $C n8n import:workflow --input=$BK"
  exit 1
fi

# ── ٦) اتأكد إنه فضل شغّال ─────────────────────────────────────────
# الاستيراد ساعات بيسيب الورك فلو متوقّف. ودي مزامنة ساعية — لو وقفت
# هنكتشفها بعد ساعات لما الأرصدة تبان قديمة.
VER="/tmp/n8n_verify_$STAMP.json"
docker exec "$C" sh -c "n8n export:workflow --all --output=$VER >/dev/null 2>&1" || true
ACTIVE="$(docker exec "$C" node -e '
  const fs=require("fs");
  const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const w=(Array.isArray(a)?a:[a]).filter(x=>String(x.name||"").includes(process.argv[2]));
  console.log(w.map(x=>(x.active?"✓ ":"✗ ")+x.name).join("\n"));
' "$VER" "$WF" 2>/dev/null)"
echo ""
echo "${B}حالة الورك فلو بعد الاستيراد:${N}"
echo "$ACTIVE" | sed 's/^/  /'
case "$ACTIVE" in
  *✗*) echo "  ${R}⚠️ وقف! فعّله من الواجهة حالًا — دي مزامنة ساعية.${N}" ;;
  *)   echo "  ${G}شغّال.${N}" ;;
esac

docker exec "$C" rm -f "$OUT" "$VER" /tmp/n8n-envify.js >/dev/null 2>&1

cat <<EOF

${G}${B}خلاص.${N}

${B}اختبر دلوقتي:${N} شغّل «$WF» يدوي من n8n وشوف Executions.
لازم ينجح زي ما كان — القيم لسه قيم السحابة.

${B}يوم التحويل:${N} في docker-compose بتاع n8n غيّر السطرين لقيم
السيرفر، وبعدها ${B}docker compose up -d n8n${N}. خلاص — مفيش
أي عقدة تتفتح.

${B}الرجوع في أي وقت:${N}
  docker cp /root/n8n_backup_$STAMP.json $C:/tmp/rb.json
  docker exec $C n8n import:workflow --input=/tmp/rb.json
EOF
