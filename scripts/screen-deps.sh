#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  كل شاشة محتاجة إيه — وهل السيرفر عنده الحاجة دي
# ═══════════════════════════════════════════════════════════════════
#  السؤال اللي بيجاوبه: مش «السيرفر مطابق للسحابة؟» لكن
#  **«كل شاشة هتشتغل بعد التحويل؟»** — وده السؤال اللي يهم فعلًا.
#
#  بيقرا كل ملف HTML ويستخرج الجداول والدوال اللي بينديها، وبيقارنهم
#  بكتالوج السيرفر، وبيطلّع لكل شاشة: محتاجة إيه، وإيه الناقص.
#
#  ═══ ليه ده مختلف عن المسح الشامل ═══
#  المسح بيقارن قاعدة بقاعدة. ده بيربط **الشاشة** بالكائن. فلو دالة
#  ناقصة، المسح بيقول «دالة ناقصة» وده بيقول «شاشة العملاء هتقع».
#  والفرق ده هو اللي يخلّيك تعرف ترتيب الاختبار صبح التحويل.
#
#  ═══ 🔴 حدود الأداة — مكتوبة عشان ما تطمّنش غلط ═══
#  بتستخرج الأسماء **الثابتة** بس. الشاشة اللي بتبني اسم الجدول
#  بتجميع نصوص (rest/v1/' + name) مش ممكن تتفحص آليًا — والأداة
#  بتعدّها وبتقولها لكل ملف بدل ما تسكت عنها.
#  وكمان: الجدول اللي الشاشة بتنديه **مباشرة** هو اللي بيتأثر
#  بالصلاحيات (anon/authenticated). اللي عبر دالة بيتخطّاها.
#
#  🔒 قراءة بس.
#
#  الاستعمال (على السيرفر):
#     ./scripts/screen-deps.sh            # الشاشات اللي فيها ناقص بس
#     ./scripts/screen-deps.sh --all      # كل الشاشات
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

REPO="${PHALIX_REPO:-/root/phalix-repo}"
COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
ALL=0
[ "${1:-}" = "--all" ] && ALL=1

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else G=''; Y=''; R=''; B=''; D=''; N=''; fi

cd "$COMPOSE_DIR" 2>/dev/null || { echo "${R}✗ مجلد سوبابيز مش موجود${N}"; exit 2; }
CID="$(docker compose ps -q db 2>/dev/null | head -1)"
[ -n "$CID" ] || { echo "${R}✗ حاوية القاعدة مش لاقيها${N}"; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── كتالوج السيرفر: الموجود فعلًا ─────────────────────────────────
q() { docker exec -i "$CID" psql -U "$DB_USER" -d postgres -tAc "$1" 2>/dev/null; }

q "select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind in ('r','p','v','m')" | tr -d ' \r' | sort -u > "$T/srv_rel"
q "select distinct p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'" | tr -d ' \r' | sort -u > "$T/srv_fn"

nrel=$(wc -l < "$T/srv_rel" | tr -d ' ')
nfn=$(wc -l < "$T/srv_fn" | tr -d ' ')

# أرضية تعقّل: كتالوج فاضي معناه الفحص ماحصلش، مش إن كله ناقص
if [ "${nrel:-0}" -lt 50 ] || [ "${nfn:-0}" -lt 50 ]; then
  echo "${R}🔴 كتالوج السيرفر رجّع $nrel جدول و$nfn دالة — رقم غير معقول.${N}"
  echo "   الفحص ماحصلش. ولو كمّلت هيقول إن كل حاجة ناقصة وده كذب."
  exit 2
fi
printf '%sكتالوج السيرفر: %s جدول/view · %s دالة%s\n' "$D" "$nrel" "$nfn" "$N"

# ── الشاشات ───────────────────────────────────────────────────────
cd "$REPO" || exit 2
files=$(ls -1 *.html 2>/dev/null; ls -1 delivery/pages/*.html 2>/dev/null)
[ -n "$files" ] || { echo "${R}✗ مالقيتش ملفات HTML في $REPO${N}"; exit 2; }

MISS_ALL="$T/miss_all"; : > "$MISS_ALL"
nscreen=0; nbad=0; ndyn=0

for f in $files; do
  nscreen=$((nscreen+1))

  # الدوال: rest/v1/rpc/X · .rpc('X') · Session.rpcAll('X')
  { grep -oh -E "rest/v1/rpc/[a-zA-Z0-9_]+" "$f" 2>/dev/null | sed 's|.*/||'
    grep -oh -E "\.rpc\(['\"][a-zA-Z0-9_]+" "$f" 2>/dev/null | sed "s|.*['\"]||"
    grep -oh -E "Session\.rpcAll\(['\"][a-zA-Z0-9_]+" "$f" 2>/dev/null | sed "s|.*['\"]||"
  } | tr -d ' \r' | grep -vx 'rpc' | sort -u > "$T/fn"

  # الجداول: rest/v1/X (مش rpc) · .from('X') · Session.getAll('X')
  { grep -oh -E "rest/v1/[a-zA-Z0-9_]+" "$f" 2>/dev/null | sed 's|.*/||'
    grep -oh -E "\.from\(['\"][a-zA-Z0-9_]+" "$f" 2>/dev/null | sed "s|.*['\"]||"
    grep -oh -E "Session\.(getAll|count)\(['\"][a-zA-Z0-9_]+" "$f" 2>/dev/null | sed "s|.*['\"]||"
  } | tr -d ' \r' | grep -vx 'rpc' | sort -u > "$T/rel"

  # نداءات ديناميكية — الأداة عماها هنا، فبتعدّها بدل ما تسكت
  dyn=$(grep -c -E "rest/v1/['\"] *\+|rest/v1/\\\$\{|\.from\(\`|\.rpc\(\`|\.from\([a-zA-Z_]" "$f" 2>/dev/null | tr -d ' ')
  dyn=${dyn:-0}
  ndyn=$((ndyn+dyn))

  miss=""
  while read -r x; do [ -n "$x" ] && ! grep -qxF "$x" "$T/srv_fn"  && miss="$miss دالة:$x"; done < "$T/fn"
  while read -r x; do [ -n "$x" ] && ! grep -qxF "$x" "$T/srv_rel" && miss="$miss جدول:$x"; done < "$T/rel"

  cf=$(grep -c . "$T/fn"); cr=$(grep -c . "$T/rel")
  [ -n "$miss" ] && { nbad=$((nbad+1)); printf '%s\n' $miss >> "$MISS_ALL"; }

  # نطبع الشاشة لو فيها ناقص، أو مع --all
  if [ -n "$miss" ] || [ "$ALL" = 1 ]; then
    if [ -n "$miss" ]; then printf '\n%s🔴 %s%s\n' "$R$B" "$f" "$N"
    else printf '\n%s✓ %s%s\n' "$G" "$f" "$N"; fi
    printf '   %sجداول مباشرة: %s · دوال: %s%s\n' "$D" "$cr" "$cf" "$N"
    [ -n "$miss" ] && printf '   %sناقص على السيرفر:%s%s\n' "$R" "$miss" "$N"
    [ "${dyn:-0}" -gt 0 ] && printf '   %s⚠️ %s نداء ديناميكي — مش مقدور أفحصه، شوفه بإيدك%s\n' "$Y" "$dyn" "$N"
  fi
done

# ── الخلاصة ──────────────────────────────────────────────────────
printf '\n%s── الخلاصة ──%s\n' "$B" "$N"
printf '  شاشات: %s · فيها ناقص: %s\n' "$nscreen" "$nbad"
printf '  %s⚠️ نداءات ديناميكية في كل الشاشات: %s — الأداة مابتشوفهاش%s\n' "$Y" "$ndyn" "$N"

if [ -s "$MISS_ALL" ]; then
  printf '\n%sالكائنات الناقصة (مرة واحدة لكل كائن):%s\n' "$B" "$N"
  sort -u "$MISS_ALL" | sed 's/^/   /'
  printf '\n%sالإصلاح: ./scripts/catchup.sh --apply%s\n' "$B" "$N"
  exit 1
fi

printf '\n%s%s✓ كل شاشة لاقية كل اللي محتاجاه على السيرفر.%s\n' "$G" "$B" "$N"
printf '   %s(الناقص الوحيد اللي مش مقدور أفحصه: النداءات الديناميكية فوق)%s\n' "$D" "$N"
exit 0
