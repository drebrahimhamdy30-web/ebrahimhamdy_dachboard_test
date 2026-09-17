#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  تكملة rotate-jwt-secret.sh — تحديث الختم المتماثل جوّه JWT_KEYS و JWT_JWKS
# ═══════════════════════════════════════════════════════════════════
#  اكتشفناها بعد أول تشغيل: الـAPI رجّع PGRST301 للمفتاح الجديد.
#
#  السبب: add-new-auth-keys.sh الرسمي بيحط نسخة من JWT_SECRET جوّه
#  JWT_KEYS و JWT_JWKS كـJWK نوعه oct:  { kty:"oct", k: base64url(secret) }
#  و PostgREST/Storage/Realtime بيتحققوا من JWT_JWKS مش من JWT_SECRET.
#  فتغيير JWT_SECRET لوحده سابهم:
#    - رافضين المفتاح الجديد
#    - وقابلين الختم القديم اللي اتكشف  ← الأخطر
#
#  الحل: استبدال قيمة k القديمة بالجديدة نصيًا في السطرين دول بس.
#  مفاتيح EC (اللي معاها) مش بتتلمس — ماتكشفتش، وتغييرها هيبوّظ
#  ANON_KEY_ASYMMETRIC و SERVICE_ROLE_KEY_ASYMMETRIC.
#
#  base64url حروفه [A-Za-z0-9_-] بس، فالاستبدال النصي بـsed آمن.
#
#  الاستعمال (من /root/supabase-project):
#     sh /root/phalix-repo/scripts/fix-jwks-oct.sh
#  وبعده:  docker compose up -d --force-recreate
# ═══════════════════════════════════════════════════════════════════
set -e

[ -f .env ] || { echo "⛔ مفيش .env هنا — لازم تكون في /root/supabase-project"; exit 1; }

old_env=$(ls -1t .env.before-jwt-* 2>/dev/null | head -1)
[ -n "$old_env" ] || { echo "⛔ مالقيتش نسخة .env.before-jwt-* — لازم rotate-jwt-secret.sh يكون اتشغّل الأول"; exit 1; }

b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
getv()  { grep "^$1=" "$2" | head -1 | cut -d= -f2- | tr -d '\r'; }

old_secret=$(getv JWT_SECRET "$old_env")
new_secret=$(getv JWT_SECRET .env)
[ -n "$old_secret" ] && [ -n "$new_secret" ] || { echo "⛔ JWT_SECRET ناقص في واحد من الملفين"; exit 1; }
[ "$old_secret" != "$new_secret" ] || { echo "⛔ الختم القديم والجديد زي بعض — rotate-jwt-secret.sh ماشتغلش؟"; exit 1; }

old_k=$(printf %s "$old_secret" | b64url)
new_k=$(printf %s "$new_secret" | b64url)

count() { grep -E "^(JWT_KEYS|JWT_JWKS)=" .env | grep -o "\"k\":\"$1\"" | wc -l | tr -d ' '; }

before_old=$(count "$old_k")
before_new=$(count "$new_k")
echo "النسخة القديمة:  $old_env"
echo "الختم القديم جوّه JWT_KEYS/JWT_JWKS:  $before_old مرة"
echo "الختم الجديد جوّه JWT_KEYS/JWT_JWKS:  $before_new مرة"

if [ "$before_old" = 0 ] && [ "$before_new" = 2 ]; then
  echo "✓ متحدّث خلاص — مفيش حاجة تتعمل"; exit 0
fi
[ "$before_old" = 2 ] || { echo "⛔ متوقع مرتين بالظبط ولقيت $before_old — مش هكمّل، قول لـClaude"; exit 1; }

printf "نحدّث؟ (y/N) "
read -r REPLY
case "$REPLY" in [Yy]) ;; *) echo "اتلغى."; exit 0 ;; esac

cp .env ".env.before-jwks-$(date +%Y%m%d-%H%M%S)"
sed -i -E "/^(JWT_KEYS|JWT_JWKS)=/ s|\"k\":\"${old_k}\"|\"k\":\"${new_k}\"|" .env

after_old=$(count "$old_k"); after_new=$(count "$new_k")
if [ "$after_old" = 0 ] && [ "$after_new" = 2 ]; then
  echo "✓ اتحدّث: الختم القديم 0 مرة · الجديد مرتين"
  echo "الخطوة الجاية:  docker compose up -d --force-recreate"
else
  echo "⛔ النتيجة مش متوقعة (قديم=$after_old جديد=$after_new) — ماتعيدش التشغيل وقول لـClaude"
  exit 1
fi
