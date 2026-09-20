#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  تحويل الشاشات وتطبيق الطيار بين السحابة والسيرفر
# ═══════════════════════════════════════════════════════════════════
#  بيتشغّل **على جهازك** (مش على السيرفر) — لأنه بيعدّل الريبوهات
#  ويعمل push، ودي محتاجة صلاحيتك على GitHub.
#
#  بيغيّر ٣ حاجات:
#    1. config.js في ريبو البرودكشن   → الشاشات (27 شاشة بتقرا منه)
#    2. config.js في ريبو التست        → نفس الحاجة للتست
#    3. app-config.json في البرودكشن   → تطبيق الطيار (بناء 71 فأعلى)
#
#  ⚠️ ليه ده مهم: من غير السكربت ده، التحويل يوم التنفيذ بيبقى تعديل
#  يدوي في ٣ ملفات وإنت مضغوط الساعة ٤ الفجر. والرجوع كمان.
#
#  الاستعمال:
#     ./scripts/switch-backend.sh status    # إحنا على إيه دلوقتي؟
#     ./scripts/switch-backend.sh server    # تحويل للسيرفر الذاتي
#     ./scripts/switch-backend.sh cloud     # رجوع للسحابة
#     ./scripts/switch-backend.sh server --dry-run
#
#  بيتأكد إن الباك إند الجديد **رادّ فعلًا** قبل ما يكتب أي حاجة —
#  مايستحملش نحوّل على باك إند واقع.
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROD="${PHALIX_PROD_REPO:-$(cd "$HERE/../ebrahimhamdy_dachboard" 2>/dev/null && pwd)}"
TEST="${PHALIX_TEST_REPO:-$HERE}"
BACKENDS="$TEST/docs/backends.json"
DRY=0

TARGET="${1:-status}"
[ "${2:-}" = "--dry-run" ] && DRY=1

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else G=''; Y=''; R=''; B=''; N=''; fi

[ -f "$BACKENDS" ] || { echo "${R}✗ مش لاقي $BACKENDS${N}"; exit 1; }
[ -d "$PROD/.git" ] || { echo "${R}✗ ريبو البرودكشن مش لاقيه: $PROD${N}"; exit 1; }

jqv() { # $1=مسار json  $2=key  $3=sub
  node -e '
    const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const v=process.argv[3]?j[process.argv[2]][process.argv[3]]:j[process.argv[2]];
    process.stdout.write(String(v??""));' "$1" "$2" "${3:-}"
}

cur_of() { # الريبو بيشاور على فين
  local f="$1/config.js"
  local u; u="$(grep -oE "supabaseUrl:[^,]*" "$f" | grep -oE "https://[^']*" | head -1)"
  case "$u" in
    *ebrahimhamdy.com*) echo server ;;
    *supabase.co*)      echo cloud ;;
    *)                  echo "؟ ($u)" ;;
  esac
}

cmd_status() {
  echo "${B}── الوضع الحالي ──${N}"
  printf '  شاشات البرودكشن : %s\n' "$(cur_of "$PROD")"
  printf '  شاشات التست     : %s\n' "$(cur_of "$TEST")"
  local p; p="$(node -e 'const fs=require("fs");try{process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).pointsTo||"؟")}catch(e){process.stdout.write("مفيش ملف")}' "$PROD/app-config.json")"
  printf '  تطبيق الطيار    : %s\n' "$p"
  printf '  المنشور فعلًا    : %s\n' "$(curl -s --max-time 10 https://phalix.ebrahimhamdy.com/app-config.json 2>/dev/null | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).pointsTo)}catch(e){process.stdout.write("؟")}})')"
}

[ "$TARGET" = status ] && { cmd_status; exit 0; }
case "$TARGET" in server|cloud) ;; *) sed -n '2,26p' "$0"; exit 1 ;; esac

URL="$(jqv "$BACKENDS" "$TARGET" url)"
[ -n "$URL" ] || { echo "${R}✗ عنوان ناقص في backends.json${N}"; exit 1; }

# ── المفتاح: مش مخزّن في الريبو (حارس الأسرار بيرفضه) ──────────────
# بنجيبه من مكانه الطبيعي: الريبو اللي شغّال على الباك إند ده حاليًا،
# أو النسخة المحلية اللي بنحفظها قبل كل تحويل.
LOCAL="$TEST/.backends.local"
key_from_config() { grep -oE "eyJ[A-Za-z0-9._-]{20,}" "$1/config.js" 2>/dev/null | head -1; }
KEY=""
[ -f "$LOCAL" ] && KEY="$(grep -m1 "^$TARGET=" "$LOCAL" 2>/dev/null | cut -d= -f2-)"
if [ -z "$KEY" ]; then
  for r in "$TEST" "$PROD"; do
    k="$(key_from_config "$r")"
    u="$(grep -oE "supabaseUrl:[^,]*" "$r/config.js" 2>/dev/null | grep -oE "https://[^']*" | head -1)"
    if [ -n "$k" ] && [ "$u" = "$URL" ]; then KEY="$k"; break; fi
  done
fi
if [ -z "$KEY" ]; then
  # آخر ملاذ: من تاريخ Git — أي نسخة قديمة من config.js كانت على العنوان ده
  KEY="$(cd "$PROD" && for c in $(git log --format=%H -20 -- config.js); do
           git show "$c:config.js" 2>/dev/null | grep -q "$URL" &&            git show "$c:config.js" | grep -oE "eyJ[A-Za-z0-9._-]{20,}" | head -1 && break
         done)"
fi
[ -n "$KEY" ] || { echo "${R}✗ مالقيتش مفتاح $TARGET${N}"
  echo "  حطّه يدويًا في: $LOCAL"
  echo "  بالشكل:  cloud=eyJ...  (سطر لكل باك إند)"; exit 1; }

echo "${B}── تحويل لـ$TARGET ──${N}"
echo "  $URL"

# ── الباك إند رادّ فعلًا؟ مانحوّلش على حاجة واقعة ───────────────────
printf '  فحص الباك إند... '
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
        "$URL/rest/v1/branches?select=name&limit=1")"
if [ "$code" != "200" ]; then
  echo "${R}HTTP $code — وقفنا${N}"
  echo "  ${Y}الباك إند ده مش رادّ. التحويل عليه هيوقّف الشاشات كلها.${N}"
  exit 1
fi
echo "${G}200 ✓${N}"

cmd_status
[ "$DRY" = 1 ] && { printf '\n'; echo "${Y}(تجربة — مفيش حاجة اتكتبت)${N}"; exit 0; }

printf "\nنكمّل؟ (y/N) "; read -r a
case "$a" in [Yy]) ;; *) echo "اتلغى."; exit 0 ;; esac

# ── نحفظ الوضع الحالي محليًا قبل ما نغيّره (عشان الرجوع) ───────────
# ملف بسيط key=value مش JSON — أسهل في القراءة والكتابة من الشل،
# ومستثنى من Git عشان حارس الأسرار بيرفض المفاتيح في الريبو.
remember() {  # $1=مسار config.js
  local u k which
  u="$(grep -oE "supabaseUrl:[^,]*" "$1" 2>/dev/null | grep -oE "https://[^']*" | head -1)"
  k="$(grep -oE "eyJ[A-Za-z0-9._-]{20,}" "$1" 2>/dev/null | head -1)"
  [ -n "$u" ] && [ -n "$k" ] || return 0
  case "$u" in *ebrahimhamdy.com*) which=server ;; *) which=cloud ;; esac
  touch "$LOCAL"; chmod 600 "$LOCAL" 2>/dev/null
  grep -v "^$which=" "$LOCAL" > "$LOCAL.tmp" 2>/dev/null || true
  echo "$which=$k" >> "$LOCAL.tmp"
  mv "$LOCAL.tmp" "$LOCAL"
}
remember "$PROD/config.js"; remember "$TEST/config.js"
echo "  ✓ الوضع الحالي اتحفظ محليًا (للرجوع)"

# ── 1+2) config.js في الريبوهين ────────────────────────────────────
for r in "$PROD" "$TEST"; do
  f="$r/config.js"
  [ -f "$f" ] || { echo "  ⚠️ مفيش config.js في $r"; continue; }
  node -e '
    const fs=require("fs");const [f,u,k]=process.argv.slice(1);
    let s=fs.readFileSync(f,"utf8");
    const before=s;
    s=s.replace(/(supabaseUrl:\s*)(["\x27])https?:\/\/[^"\x27]*\2/, `$1$2${u}$2`);
    s=s.replace(/(supabaseAnonKey:\s*)(["\x27])ey[^"\x27]*\2/, `$1$2${k}$2`);
    if(s===before) throw new Error("مالقيتش السطرين في "+f);
    fs.writeFileSync(f,s);
  ' "$f" "$URL" "$KEY" && echo "  ✓ $(basename "$r")/config.js"
done

# ── 3) app-config.json (تطبيق الطيار) ──────────────────────────────
node -e '
  const fs=require("fs");const [f,u,k,t]=process.argv.slice(1);
  const j=JSON.parse(fs.readFileSync(f,"utf8"));
  j.supabaseUrl=u; j.supabaseAnonKey=k; j.pointsTo=t;
  j.updatedAt=new Date().toISOString().slice(0,10);
  fs.writeFileSync(f, JSON.stringify(j,null,2)+"\n");
' "$PROD/app-config.json" "$URL" "$KEY" "$TARGET" && echo "  ✓ app-config.json"

# ── الرفع ──────────────────────────────────────────────────────────
msg="تحويل الباك إند إلى $TARGET"
( cd "$PROD" && git add config.js app-config.json && git commit -q -m "$msg

الشاشات وتطبيق الطيار بيشاوروا على $URL.
الرجوع: ./scripts/switch-backend.sh $([ "$TARGET" = server ] && echo cloud || echo server)" \
  && git push -q && echo "  ✓ البرودكشن اترفع" ) || echo "  ${Y}⚠️ البرودكشن: مفيش تغيير أو الرفع فشل${N}"

( cd "$TEST" && git add config.js && git commit -q -m "$msg" && git push -q && echo "  ✓ التست اترفع" ) \
  || echo "  ${Y}⚠️ التست: مفيش تغيير أو الرفع فشل${N}"

cat <<EOF

${G}${B}اتحوّل لـ$TARGET${N}

${Y}ملحوظات:${N}
  • الشاشات: GitHub Pages بياخد دقيقة–اتنين قبل ما ينشر
  • التطبيقات: كل تطبيق بيقرا الإعداد أول ما يفتح — يعني الطيار
    لازم يقفل التطبيق ويفتحه (أو الخدمة تعيد تشغيل نفسها)
  • النسخ الأقدم من بناء 71 **مش بتقرا الملف** وهتفضل على السحابة

للرجوع:  ./scripts/switch-backend.sh $([ "$TARGET" = server ] && echo cloud || echo server)
EOF
