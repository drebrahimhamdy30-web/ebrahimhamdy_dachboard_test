#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  فحص صحة السيرفر — وبيبعت إيميل لما حاجة تقع (أو ترجع)
# ═══════════════════════════════════════════════════════════════════
#  ⚠️ **حدّ ده**: السكربت ده شغّال **على** السيرفر. لو السيرفر نفسه
#     وقع، مش هيبعتلك حاجة — هيكون واقع هو كمان. عشان كده لازم معاه
#     مراقبة خارجية (UptimeRobot أو أي خدمة ping مجانية) تمسك الحالة
#     دي. ده مش اختياري.
#
#  ═══ بيفحص إيه ═══
#    • القرص والذاكرة
#    • حاويات سوبابيز شغّالة وصحّتها تمام
#    • الـAPI رادّ **من برّه** (بيعدّي على nginx وكلاودفلير زي المستخدم)
#    • آخر نسخة احتياطية عمرها كام
#    • النسخة الخارجية اترفعت
#    • آخر مزامنة من السحابة
#    • 🔒 مهام cron على السيرفر = صفر (العزل لسه شغّال)
#
#  ═══ مابيزنّش ═══
#  بيبعت إيميل **بس لما الحالة تتغيّر**: أول ما مشكلة تظهر، وأول ما
#  تتصلح. مش كل ربع ساعة. إنذار بيتكرر = إنذار بيتجاهل.
#
#  الاستعمال:
#     ./server-health.sh          # فحص وعرض (للتجربة اليدوية)
#     ./server-health.sh -q       # للكرون: ساكت، بيبعت إيميل عند التغيير
#     ./server-health.sh --test-mail   # يجرّب الإيميل بس
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

MAILTO="${PHALIX_MAILTO:-drebrahimhamdy30@gmail.com}"
STATE="${PHALIX_HEALTH_STATE:-/var/lib/phalix-health.state}"
COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
BACKUP_DIR="${PHALIX_BACKUP_DIR:-/root/backups}"
DOMAIN="${PHALIX_DOMAIN:-https://supabase.ebrahimhamdy.com}"
REMOTE="${PHALIX_REMOTE:-gdrive:phalix-backups}"
DISK_MAX="${PHALIX_DISK_MAX:-92}"        # نسبة امتلاء القرص المقبولة
MEM_MIN_MB="${PHALIX_MEM_MIN:-400}"      # أقل ذاكرة متاحة مقبولة
AGE_MAX_H="${PHALIX_AGE_MAX_H:-30}"      # عمر النسخة/المزامنة بالساعات
QUIET=0

send_mail() {  # $1=عنوان  $2=نص
  if command -v msmtp >/dev/null 2>&1; then
    printf 'To: %s\nFrom: phalix-server <%s>\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
      "$MAILTO" "$MAILTO" "$1" "$2" | msmtp "$MAILTO" 2>/dev/null
  elif command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$2" | mail -s "$1" "$MAILTO" 2>/dev/null
  else
    echo "⚠️ مفيش أداة إرسال إيميل (msmtp) — الإنذار مش هيتبعت" >&2
    return 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet) QUIET=1 ;;
    --test-mail)
      if send_mail "فحص إرسال — سيرفر فاليكس" "لو وصلتك الرسالة دي، الإيميل مظبوط.
الوقت: $(date '+%Y-%m-%d %H:%M')"; then echo "✓ اتبعت لـ$MAILTO — شوف بريدك (والسبام)"; else echo "✗ فشل الإرسال"; exit 1; fi
      exit 0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "خيار مش معروف: $1" >&2; exit 2 ;;
  esac
  shift
done

FAILED=""; DETAIL=""
fail() { FAILED="$FAILED $1"; DETAIL="$DETAIL
  ✗ $2"; }
ok()   { [ "$QUIET" = 1 ] || printf '  ✓ %s\n' "$1"; }

cd "$COMPOSE_DIR" 2>/dev/null || { echo "مجلد سوبابيز مش موجود"; exit 1; }

# ── القرص ──────────────────────────────────────────────────────────
d=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
case "$d" in *[!0-9]*|"") d=-1 ;; esac    # خرج غير متوقع = نتخطّى بدل إنذار كاذب
[ "$d" -gt 100 ] 2>/dev/null && d=-1      # نسبة فوق 100% = خرج غلط مش قرص مليان
if [ "$d" -lt 0 ]; then :
elif [ "$d" -ge "$DISK_MAX" ]; then
  fail disk "القرص $d% مليان (الحد $DISK_MAX%) — لو امتلى بوستجرس بيقف"
else ok "القرص $d%"; fi

# ── الذاكرة ────────────────────────────────────────────────────────
m=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
if [ -z "$m" ]; then :                    # free مش متاحة — نتخطّى
elif [ "$m" -lt "$MEM_MIN_MB" ]; then
  fail mem "الذاكرة المتاحة ${m}MB بس (الحد ${MEM_MIN_MB}MB)"
else ok "الذاكرة ${m}MB متاحة"; fi

# ── الحاويات ───────────────────────────────────────────────────────
bad=""
for c in supabase-db supabase-rest supabase-auth supabase-edge-functions supabase-pooler; do
  st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo "مش موجودة")
  case "$st" in
    running|running/healthy) ;;
    running/starting) ;;
    *) bad="$bad $c($st)" ;;
  esac
done
if [ -n "$bad" ]; then fail containers "حاويات مش تمام:$bad"; else ok "الحاويات شغّالة"; fi

# ── الـAPI من برّه (بيعدّي على nginx وكلاودفلير زي المستخدم بالظبط) ──
# بنستعمل المفتاح العام من .env عشان الفحص يعدّي على السلسلة كلها
# (nginx ← البوابة ← PostgREST ← القاعدة) زي المستخدم بالظبط. من غير
# مفتاح كنا هناخد 401 من طبقة الإذن ونفتكر إن كل حاجة تمام وهي مش كده.
AK=$(grep -m1 '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d '\r')
if [ -n "$AK" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
         -H "apikey: $AK" -H "Authorization: Bearer $AK" \
         "$DOMAIN/rest/v1/branches?select=name&limit=1" 2>/dev/null || echo 000)
  want=200
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$DOMAIN/auth/v1/health" 2>/dev/null || echo 000)
  want=401   # من غير مفتاح، 401 معناها إن السلسلة واصلة لطبقة الإذن
fi
if [ "$code" != "$want" ]; then
  fail api "الـAPI من برّه رجّع $code (المتوقع $want) — المستخدمين مش بيوصلوا"
else ok "الـAPI رادّ من برّه ($code)"; fi

# ── آخر نسخة احتياطية ──────────────────────────────────────────────
last=$(ls -1d "$BACKUP_DIR"/2* 2>/dev/null | tail -1)
if [ -z "$last" ]; then
  fail backup "مفيش أي نسخة احتياطية"
else
  age=$(( ( $(date +%s) - $(stat -c %Y "$last") ) / 3600 ))
  if [ "$age" -gt "$AGE_MAX_H" ]; then
    fail backup "آخر نسخة عمرها $age ساعة — الكرون واقف؟"
  else ok "آخر نسخة من $age ساعة"; fi
fi

# ── النسخة الخارجية ────────────────────────────────────────────────
if command -v rclone >/dev/null 2>&1; then
  rlast=$(rclone lsf "$REMOTE" 2>/dev/null | grep '\.enc$' | sort | tail -1)
  if [ -z "$rlast" ]; then
    fail offsite "مفيش نسخة على Drive — لو السيرفر ضاع مفيش رجعة"
  else
    # الاسم شكله 20260919-0300.tar.gz.enc
    rd=$(echo "$rlast" | cut -c1-8)
    rage=$(( ( $(date +%s) - $(date -d "$rd" +%s 2>/dev/null || echo 0) ) / 86400 ))
    if [ "$rage" -gt 2 ]; then
      fail offsite "آخر نسخة على Drive من $rage يوم"
    else ok "النسخة الخارجية محدّثة"; fi
  fi
fi

# ── آخر مزامنة من السحابة ──────────────────────────────────────────
CID=$(docker compose ps -q db 2>/dev/null | head -1)
if [ -n "$CID" ]; then
  h=$(docker exec -i "$CID" psql -U supabase_admin -d postgres -tAc \
      "select coalesce(round(extract(epoch from now()-max(ran_at))/3600)::int, 999) from public.cloud_sync_log" 2>/dev/null | tr -d ' ')
  if [ "${h:-999}" -gt "$AGE_MAX_H" ]; then
    fail sync "آخر مزامنة من ${h} ساعة — البيانات بتقدم"
  else ok "آخر مزامنة من ${h} ساعة"; fi

  # 🔒 العزل: أي كرون على السيرفر قبل التحويل = إشعارات مزدوجة للطيارين
  j=$(docker exec -i "$CID" psql -U supabase_admin -d postgres -tAc \
      "select count(*) from cron.job" 2>/dev/null | tr -d ' ')
  if [ "${j:-0}" != "0" ]; then
    fail isolation "🔴 فيه $j مهمة cron شغّالة على السيرفر — الطيارين ممكن ياخدوا إشعارات مزدوجة"
  else ok "العزل شغّال (صفر cron)"; fi
fi

# ── قارن بالحالة السابقة: نبعت عند التغيير بس ──────────────────────
NOW="$(echo $FAILED | tr ' ' '\n' | sort | tr '\n' ' ')"
PREV="$(cat "$STATE" 2>/dev/null || echo '')"
mkdir -p "$(dirname "$STATE")"; echo "$NOW" > "$STATE"

if [ "$NOW" = "$PREV" ]; then
  [ "$QUIET" = 1 ] || echo "(مفيش تغيير عن آخر فحص)"
  exit 0
fi

if [ -n "$FAILED" ]; then
  send_mail "🔴 سيرفر فاليكس: $(echo $FAILED | wc -w) مشكلة" "الفحص لقى:
$DETAIL

الوقت: $(date '+%Y-%m-%d %H:%M') · السيرفر: $(hostname)

للفحص اليدوي:  /root/phalix-repo/scripts/server-health.sh"
  [ "$QUIET" = 1 ] || echo "📧 اتبعت رسالة بالمشاكل"
elif [ -n "$PREV" ]; then
  send_mail "✅ سيرفر فاليكس: رجع تمام" "كل الفحوصات عدّت.
اللي كان واقع قبل كده:$PREV

الوقت: $(date '+%Y-%m-%d %H:%M')"
  [ "$QUIET" = 1 ] || echo "📧 اتبعت رسالة إن كل حاجة رجعت"
fi

[ -n "$FAILED" ] && exit 1 || exit 0
