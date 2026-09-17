#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  نسخة احتياطية لسيرفر سوبابيز الذاتي
# ═══════════════════════════════════════════════════════════════════
#  بياخد ٤ حاجات — القاعدة لوحدها مش كفاية للرجوع:
#    1. القاعدة كاملة        pg_dump -Fc   (بيانات + سكيما + الدوال)
#    2. الأدوار وكلمات سرها  pg_dumpall --globals-only
#    3. الإعدادات والأسرار   .env + docker-compose.yml + volumes/functions
#    4. ملفات التخزين        volumes/storage  (لو موجود)
#
#  ⚠️ الملفات دي فيها أسرار → المجلد 700 والملفات 600. ماتنسخهاش لمكان عام.
#  ⚠️ نسخة على نفس السيرفر **مش** نسخة احتياطية. لو السيرفر ضاع ضاعت معاه.
#     لازم تتسحب برّه — آخر سطر في الخرج فيه أمر السحب.
#
#  الاستعمال:
#     ./server-backup.sh              # ياخد نسخة
#     ./server-backup.sh -n           # تجربة: يقول هيعمل إيه بس
#     ./server-backup.sh -q           # للكرون: ساكت إلا لو حصلت مشكلة
#     ./server-backup.sh --verify-last  # يتأكد إن آخر نسخة سليمة
#
#  الرجوع من نسخة: docs/server_backup_restore.md
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

DIR="${PHALIX_BACKUP_DIR:-/root/backups}"
COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
KEEP_DAILY="${PHALIX_KEEP_DAILY:-14}"    # آخر ١٤ نسخة
KEEP_WEEKLY="${PHALIX_KEEP_WEEKLY:-8}"   # + نسخة الجمعة لآخر ٨ أسابيع
MIN_DB_MB="${PHALIX_MIN_DB_MB:-20}"      # أقل من كده = ناقصة أكيد
DRY=0; QUIET=0; VERIFY_ONLY=0; NOTABLE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)   DRY=1 ;;
    -q|--quiet)     QUIET=1 ;;
    --verify-last)  VERIFY_ONLY=1 ;;
    -h|--help)      sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "خيار مش معروف: $1" >&2; exit 2 ;;
  esac
  shift
done

# الوضع الصامت — الكرون يومي، مش عايزين رسالة كل يوم إلا لو فيه مشكلة
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

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=''; G=''; Y=''; R=''; N=''; fi
stamp() { [ -t 1 ] || printf '[%s] ' "$(date '+%Y-%m-%d %H:%M')"; }
say()  { stamp; printf '%s\n' "$*"; }
step() { printf '\n'; stamp; printf '%s▸ %s%s\n' "$B" "$*" "$N"; }
ok()   { stamp; printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { NOTABLE=1; stamp; printf '  %s⚠%s %s\n' "$Y" "$N" "$*"; }
die()  { NOTABLE=1; stamp; printf '  %s✗ %s%s\n' "$R" "$*" "$N"; exit 1; }

mb()   { echo $(( $(stat -c %s "$1" 2>/dev/null || echo 0) / 1048576 )); }
dirs() { ls -1d "$DIR"/2* 2>/dev/null || true; }
dow()  { date -d "$(basename "$1" | cut -d- -f1)" +%u 2>/dev/null || echo 0; }

# ── فحص نسخة: موجودة وسليمة وحجمها معقول ──────────────────────────
verify_dir() {
  d="$1"; n="$(basename "$d")"
  for f in db.dump globals.sql config.tar.gz; do
    [ -s "$d/$f" ] || { warn "$n: $f ناقص أو فاضي"; return 1; }
  done
  m=$(mb "$d/db.dump")
  [ "$m" -ge "$MIN_DB_MB" ] || { warn "$n: db.dump ${m}MB بس — مشكوك فيها"; return 1; }
  gzip -t "$d/config.tar.gz" 2>/dev/null || { warn "$n: config.tar.gz تالف"; return 1; }
  # أهم فحص: pg_restore يقدر يقرا فهرس الملف؟ لو اتقطع هيفشل هنا
  docker compose exec -T db pg_restore -l /dev/stdin < "$d/db.dump" >/dev/null 2>&1 \
    || { warn "$n: pg_restore مش قادر يقراها — تالفة"; return 1; }
  ok "$n سليمة (${m}MB)"
}

cd "$COMPOSE_DIR" 2>/dev/null || die "مجلد سوبابيز مش موجود: $COMPOSE_DIR"

if [ "$VERIFY_ONLY" = 1 ]; then
  last="$(dirs | tail -1)"
  [ -n "$last" ] || die "مفيش أي نسخة في $DIR"
  step "فحص آخر نسخة"
  verify_dir "$last" || die "آخر نسخة مش سليمة"
  exit 0
fi

[ "$DRY" = 1 ] && say "${Y}═══ تجربة: مش هيتكتب أي حاجة ═══${N}"

# ── ١) تأكيدات ─────────────────────────────────────────────────────
step "فحص قبل البدء"
docker compose ps db 2>/dev/null | grep -q db || die "خدمة db مش لاقيها — إنت في المجلد الصح؟"
avail=$(df -Pm "$(dirname "$DIR")" | awk 'NR==2{print $4}')
say "  المساحة الفاضية: $((avail/1024))GB"
[ "$avail" -ge 2048 ] || warn "أقل من 2GB فاضي — النسخة ممكن تقع في النص"
ok "الحاوية شغّالة"

TS="$(date +%Y%m%d-%H%M)"
OUT="$DIR/$TS"

if [ "$DRY" = 1 ]; then
  say "  (تجربة) هيتعمل: $OUT/{db.dump,globals.sql,config.tar.gz}"
  say "  (تجربة) الاستبقاء: آخر $KEEP_DAILY نسخة + جمعة آخر $KEEP_WEEKLY أسبوع"
  say "  (تجربة) الموجود حاليًا: $(dirs | wc -l) نسخة"
  exit 0
fi

mkdir -p "$OUT"; chmod 700 "$DIR" "$OUT"

# ── ٢) القاعدة ─────────────────────────────────────────────────────
# -Fc = صيغة مضغوطة بيقراها pg_restore (بتسمح ترجّع جدول واحد لوحده)
step "تصدير القاعدة"
docker compose exec -T db pg_dump -U "$DB_USER" -d postgres -Fc > "$OUT/db.dump" \
  || die "pg_dump فشل — النسخة دي مش كاملة"
ok "db.dump — $(mb "$OUT/db.dump")MB"

# الأدوار مش جوّه pg_dump — من غيرها الرجوع بيفشل بـ«role does not exist»
step "تصدير الأدوار"
docker compose exec -T db pg_dumpall -U "$DB_USER" --globals-only > "$OUT/globals.sql" \
  || die "pg_dumpall فشل"
ok "globals.sql — $(wc -l < "$OUT/globals.sql") سطر"

# ── ٣) الإعدادات والأسرار ──────────────────────────────────────────
step "تصدير الإعدادات"
tar -czf "$OUT/config.tar.gz" -C "$COMPOSE_DIR" \
  .env docker-compose.yml volumes/functions volumes/api volumes/pooler 2>/dev/null \
  || warn "بعض ملفات الإعدادات مش موجودة — اتخطّت"
ok "config.tar.gz — $(mb "$OUT/config.tar.gz")MB"

# ملفات التخزين (صور/مرفقات) — ممكن تكون كبيرة فمنفصلة
if [ -d "$COMPOSE_DIR/volumes/storage" ]; then
  step "تصدير ملفات التخزين"
  tar -czf "$OUT/storage.tar.gz" -C "$COMPOSE_DIR" volumes/storage \
    && ok "storage.tar.gz — $(mb "$OUT/storage.tar.gz")MB" || warn "فشل أرشفة التخزين"
fi

chmod 600 "$OUT"/*

# ── ٤) الفحص — نسخة ماتتفحصش = نسخة ماحدش يعرف هي سليمة ولا لأ ─────
step "فحص النسخة"
verify_dir "$OUT" || die "النسخة مش سليمة — سايبها مكانها للفحص: $OUT"

# ── ٥) حذف القديم ──────────────────────────────────────────────────
# بنمسك: آخر KEEP_DAILY نسخة + آخر KEEP_WEEKLY نسخة يوم جمعة
step "تنظيف القديم"
keep="$( { dirs | tail -n "$KEEP_DAILY"
           # الجُمَع — || true لأن آخر لفة لو مش جمعة بترجّع فشل
           # والحلقة بتورّث حالتها، و set -e كان بيقفل السكربت هنا بصمت
           { dirs | while read -r d; do
               if [ "$(dow "$d")" = 5 ]; then echo "$d"; fi
             done || true; } | tail -n "$KEEP_WEEKLY"
         } | sort -u )"
deleted=0
for d in $(dirs); do
  printf '%s\n' "$keep" | grep -qxF "$d" && continue
  rm -rf "$d"; deleted=$((deleted+1))
done
[ "$deleted" -gt 0 ] && say "  اتمسح $deleted نسخة قديمة" || ok "مفيش حاجة تتمسح"

# ── ٦) الخلاصة ─────────────────────────────────────────────────────
printf '\n'; stamp; printf '%s── الخلاصة ──%s\n' "$B" "$N"
stamp; printf '  النسخة: %s (%sMB)\n' "$TS" "$(du -sm "$OUT" | cut -f1)"
stamp; printf '  المحفوظ: %s نسخة · الإجمالي: %s\n' "$(dirs | wc -l)" "$(du -sh "$DIR" | cut -f1)"
if [ -t 1 ]; then
  printf '\n  %s⚠ النسخة على نفس السيرفر — لو ضاع السيرفر ضاعت معاه.%s\n' "$Y" "$N"
  printf '    اسحبها على جهازك:  scp -r root@193.181.208.115:%s .\n' "$OUT"
fi
