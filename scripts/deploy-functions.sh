#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  نشر الـEdge Functions على السيرفر الذاتي
# ═══════════════════════════════════════════════════════════════════
#  يتشغّل على السيرفر نفسه بصلاحية root.
#
#  النشر هنا = نسخ ملفات في المجلد اللي حاوية edge-runtime بتقرا منه.
#  مفيش Management API في النسخة الذاتية زي السحابة.
#
#  الاستعمال:
#     ./deploy-functions.sh                 # يسحب من Git وينشر ويعيد التشغيل
#     ./deploy-functions.sh --no-restart    # ينشر بس (التعديلات مش هتبان)
#     ./deploy-functions.sh -n              # تجربة: يقول هيعمل إيه من غير ما يعمل
#     ./deploy-functions.sh --from-dir /path/to/functions
#
#  ⚠️ مجلد main/ هو راوتر الـedge-runtime — السكربت **مابيلمسوش** أبدًا.
#  ⚠️ دالة موجودة على السيرفر ومش في الريبو: بيحذّر منها ومابيحذفهاش.
#     الحذف قرار بني آدم مش سكربت.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_URL="https://github.com/drebrahimhamdy30-web/ebrahimhamdy_dachboard_test"
REPO_DIR="/root/phalix-repo"
DEST="/root/supabase-project/volumes/functions"
COMPOSE_DIR="/root/supabase-project"
CONTAINER="supabase-edge-functions"
SRC=""            # يتحدد من --from-dir أو من الريبو
DRY=0
RESTART=1

# الأسرار اللي الدوال بتحتاجها — بنفحص وجودها بس، مابنطبعش قيمها
NEEDED_ENV=(SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY SERVICE_ROLE_KEY SYNC_KEY
            EPLUS_BRANCHES PHARMA_MARKET_AUTH GOOGLE_MAPS_API_KEY)

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)   DRY=1 ;;
    --no-restart)   RESTART=0 ;;
    --from-dir)     SRC="${2:-}"; shift ;;
    -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "خيار مش معروف: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$DRY" = 1 ] && say $'\033[33m═══ تجربة: مش هيتكتب أي حاجة ═══\033[0m'

# ── ١) تأكيدات قبل أي حاجة ─────────────────────────────────────────
step "فحص البيئة"
[ -d "$DEST" ] || die "مجلد الدوال مش موجود: $DEST"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "الحاوية مش موجودة: $CONTAINER"
[ -d "$DEST/main" ] || warn "مفيش main/ — الراوتر ناقص، النداءات هتفشل"
ok "المجلد والحاوية موجودين"

# ── ٢) مصدر الملفات ────────────────────────────────────────────────
if [ -z "$SRC" ]; then
  step "تحديث الريبو"
  if [ -d "$REPO_DIR/.git" ]; then
    if [ "$DRY" = 1 ]; then say "  (تجربة) git pull في $REPO_DIR"
    else git -C "$REPO_DIR" pull --ff-only --quiet && ok "اتحدّث"; fi
  else
    if [ "$DRY" = 1 ]; then say "  (تجربة) git clone → $REPO_DIR"
    else git clone --depth 1 --quiet "$REPO_URL" "$REPO_DIR" && ok "اتنسخ"; fi
  fi
  SRC="$REPO_DIR/supabase/functions"
fi
[ -d "$SRC" ] || die "مصدر الدوال مش موجود: $SRC"
say "  المصدر: $SRC"

# ── ٣) النسخ ───────────────────────────────────────────────────────
step "نشر الدوال"
added=0; updated=0; same=0; bad=0
for d in "$SRC"/*/; do
  slug="$(basename "$d")"
  [ "$slug" = "main" ] && { warn "main/ اتخطّى (راوتر السيرفر، مش من الريبو)"; continue; }

  if [ ! -f "$d/index.ts" ]; then warn "$slug: مفيش index.ts — اتخطّى"; bad=$((bad+1)); continue; fi

  if [ ! -d "$DEST/$slug" ]; then
    state="جديدة"; added=$((added+1))
  elif ! diff -rq "$d" "$DEST/$slug" >/dev/null 2>&1; then
    state="اتغيّرت"; updated=$((updated+1))
  else
    state=""; same=$((same+1))
  fi

  if [ -n "$state" ]; then
    if [ "$DRY" = 1 ]; then say "  (تجربة) $slug — $state"
    else
      mkdir -p "$DEST/$slug"
      cp -r "$d"/. "$DEST/$slug"/
      ok "$slug — $state"
    fi
  fi
done
[ "$same" -gt 0 ] && say "  ($same زي ما هي)"
[ "$bad"  -gt 0 ] && warn "$bad مجلد بلا index.ts"

# دوال على السيرفر مش في الريبو — تحذير بس
step "مقارنة بالسيرفر"
orphans=0
for d in "$DEST"/*/; do
  slug="$(basename "$d")"
  [ "$slug" = "main" ] && continue
  [ -d "$SRC/$slug" ] || { warn "$slug: على السيرفر ومش في الريبو — راجعها يدويًا"; orphans=$((orphans+1)); }
done
[ "$orphans" = 0 ] && ok "مفيش دوال زيادة"

# ── ٤) فحص الأسرار (الأسماء بس) ────────────────────────────────────
step "فحص متغيّرات البيئة"
env_names="$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1)"
missing=()
for k in "${NEEDED_ENV[@]}"; do
  printf '%s\n' "$env_names" | grep -qx "$k" || missing+=("$k")
done
if [ ${#missing[@]} -eq 0 ]; then ok "كل الأسرار المطلوبة موجودة"
else
  warn "ناقص: ${missing[*]}"
  say  "     الدوال اللي محتاجاها هتردّ secret_not_set."
  say  "     حطّهم في $COMPOSE_DIR/.env تحت خدمة functions وبعدين:"
  say  "       cd $COMPOSE_DIR && docker compose up -d functions"
  say  "     ⚠️ docker restart مش كفاية لمتغيّرات البيئة."
fi

# ── ٥) إعادة التشغيل ───────────────────────────────────────────────
step "إعادة التشغيل"
if [ "$RESTART" = 0 ]; then
  warn "اتخطّت (--no-restart) — التعديلات ممكن ماتبانش لحد ما تعيد التشغيل"
elif [ "$((added+updated))" -eq 0 ]; then
  ok "مفيش تغيير، مش محتاجة"
elif [ "$DRY" = 1 ]; then
  say "  (تجربة) docker restart $CONTAINER"
else
  say "  ⚠️ الدوال هتبقى مقطوعة ثواني"
  docker restart "$CONTAINER" >/dev/null && ok "اتعادت"
  for i in $(seq 1 15); do
    st="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo '?')"
    [ "$st" = "running" ] && { ok "شغّالة"; break; }
    [ "$i" = 15 ] && warn "لسه مش شغّالة — شوف: docker logs --tail 50 $CONTAINER"
    sleep 1
  done
fi

# ── ٦) الخلاصة ─────────────────────────────────────────────────────
total=$(find "$DEST" -maxdepth 1 -mindepth 1 -type d ! -name main | wc -l)
printf '\n\033[1m── الخلاصة ──\033[0m\n'
printf '  جديدة: %s · اتغيّرت: %s · زي ما هي: %s\n' "$added" "$updated" "$same"
printf '  إجمالي الدوال على السيرفر: %s (+ main)\n' "$total"
[ ${#missing[@]} -gt 0 ] && printf '  \033[33m⚠ أسرار ناقصة: %s\033[0m\n' "${#missing[@]}"
printf '\n  للتأكد إن دالة بتتحمّل فعلاً:\n'
printf '    docker logs --tail 30 %s\n' "$CONTAINER"
printf '\n  \033[33m⚠ ماتشغّلش الكرون هنا والسحابة شغّالة — إشعارات مزدوجة للطيارين.\033[0m\n'
