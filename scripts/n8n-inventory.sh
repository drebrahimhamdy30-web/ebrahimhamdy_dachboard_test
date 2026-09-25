#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  جرد n8n قبل التحويل — قراءة بس
# ═══════════════════════════════════════════════════════════════════
#  بيصدّر كل الورك فلوز من n8n وبيعدّ العقد اللي بتلمس القاعدة،
#  ويقول لكل واحدة على السحابة ولا السيرفر وإيه اللي لازم يتغيّر.
#
#  ليه محتاجينه: تحويل n8n هو أكبر بند يدوي يوم التحويل، والوحيد
#  اللي ممكن يفشل **بصمت** — ورك فلو فاضل على السحابة هيفضل يشتغل
#  «بنجاح» ويكتب في قاعدة متجمّدة محدش بيقرا منها. مفيش أي رسالة
#  خطأ في أي مكان. فالجرد لازم يبقى من التصدير الحي مش من الذاكرة.
#
#  🔒 مابيغيّرش أي حاجة، ومابيطبعش أي سر.
#
#  الاستعمال (من السيرفر):
#     /root/phalix-repo/scripts/n8n-inventory.sh
#     /root/phalix-repo/scripts/n8n-inventory.sh --keep   # يسيب التصدير
#
#  التصدير بيتمسح في الآخر (فيه مفاتيح) إلا مع --keep.
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

if [ -t 1 ]; then R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else R=''; Y=''; B=''; N=''; fi

# ── نلاقي حاوية n8n ────────────────────────────────────────────────
C="${N8N_CONTAINER:-}"
if [ -z "$C" ]; then
  C="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE '^n8n$|n8n' | head -1)"
fi
[ -n "$C" ] || { echo "${R}✗ مالقيتش حاوية n8n شغّالة${N}"
                 echo "  شوف: docker ps --format '{{.Names}}'"
                 echo "  ولو اسمها مختلف: N8N_CONTAINER=اسمها $0"; exit 1; }
echo "${B}حاوية n8n:${N} $C"

# ── التصدير ────────────────────────────────────────────────────────
# n8n CLI بيصدّر من أي مخزن (sqlite أو postgres) — فمش محتاجين نعرف
# هو مخزّن فين ولا كلمة سر ولا حاجة.
TMPJ="/tmp/n8n_wf_$$.json"
printf '  بصدّر الورك فلوز... '
if ! docker exec -u node "$C" n8n export:workflow --all --output="$TMPJ" >/dev/null 2>&1; then
  # بعض النسخ محتاجة تتشغّل من غير -u node
  if ! docker exec "$C" n8n export:workflow --all --output="$TMPJ" >/dev/null 2>&1; then
    echo "${R}فشل${N}"
    echo "  جرّب يدوي وشوف الرسالة:"
    echo "    docker exec -u node $C n8n export:workflow --all --output=/tmp/wf.json"
    exit 1
  fi
fi
CNT="$(docker exec "$C" sh -c "grep -o '\"name\"' '$TMPJ' | wc -l" 2>/dev/null | tr -d ' \r')"
echo "تمام"

# ── الفحص جوّه الحاوية (فيها node) ────────────────────────────────
docker cp "$HERE/n8n-inventory.js" "$C:/tmp/n8n-inventory.js" >/dev/null 2>&1 \
  || { echo "${R}✗ مقدرتش أنقل ملف الفحص للحاوية${N}"; exit 1; }

docker exec -e N8N_CHECKLIST=/tmp/n8n_cutover_checklist.md \
  "$C" node /tmp/n8n-inventory.js "$TMPJ"
rc=$?

# ── نطلّع التشيك ليست برّه ─────────────────────────────────────────
if docker cp "$C:/tmp/n8n_cutover_checklist.md" /root/n8n_cutover_checklist.md >/dev/null 2>&1; then
  echo "📋 نسخة على السيرفر: /root/n8n_cutover_checklist.md"
fi

# ── تنضيف: التصدير فيه مفاتيح ─────────────────────────────────────
if [ "$KEEP" = 1 ]; then
  echo "${Y}⚠️ التصدير متسايب في الحاوية على $TMPJ — فيه مفاتيح. امسحه لما تخلص:${N}"
  echo "   docker exec $C rm -f $TMPJ"
else
  docker exec "$C" rm -f "$TMPJ" /tmp/n8n-inventory.js >/dev/null 2>&1
fi

exit $rc
