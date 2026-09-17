#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  تغيير JWT_SECRET + ANON_KEY + SERVICE_ROLE_KEY — بس
#  على Supabase الذاتي (supabase.ebrahimhamdy.com)
# ═══════════════════════════════════════════════════════════════════
#  ليه مش utils/generate-keys.sh بتاع Supabase:
#    بيغيّر ١٤ مفتاح مرة واحدة، ومنهم VAULT_ENC_KEY و REALTIME_DB_ENC_KEY
#    (بيانات متشفّرة بيهم هتبقى مستحيل تتقري)، ومنهم POSTGRES_PASSWORD
#    في .env بس من غير القاعدة — وده لوحده بيوقّف السيرفر.
#    السكربت ده بيلمس التلات مفاتيح المرتبطين ببعض وبس.
#
#  طريقة التوقيع نفس generate-keys.sh الرسمي بالحرف
#  (HS256 بـ openssl -hmac على JWT_SECRET كنص)، عشان GoTrue و PostgREST
#  يقبلوا التوكنات.
#
#  ⚠️ مابيعيدش تشغيل حاجة. بعده:
#       docker compose up -d --force-recreate
#  ⚠️ كل اللي داخلين على السيرفر هيخرجوا (توكناتهم القديمة مش هتعدّي).
#  ⚠️ ANON_KEY الجديد لازم يتحط في config.js بتاع التست.
#
#  الاستعمال (من /root/supabase-project):
#     sh /root/phalix-repo/scripts/rotate-jwt-secret.sh
# ═══════════════════════════════════════════════════════════════════
set -e

[ -f .env ] || { echo "⛔ مفيش .env هنا — لازم تكون في /root/supabase-project"; exit 1; }
[ -f docker-compose.yml ] || { echo "⛔ مفيش docker-compose.yml هنا"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "⛔ openssl مش موجود"; exit 1; }

for k in JWT_SECRET ANON_KEY SERVICE_ROLE_KEY; do
  grep -q "^$k=" .env || { echo "⛔ $k مش موجود في .env — مش هكمّل"; exit 1; }
done

b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

jwt_secret="$(openssl rand -base64 30 | tr -d '\n')"
header='{"alg":"HS256","typ":"JWT"}'
iat=$(date +%s)
exp=$((iat + 5 * 3600 * 24 * 365))

sign() {
  hp=$(printf %s "$header" | b64url)
  pp=$(printf %s "$1" | b64url)
  sig=$(printf %s "$hp.$pp" | openssl dgst -binary -sha256 -hmac "$jwt_secret" | b64url)
  printf %s "$hp.$pp.$sig"
}

anon_key=$(sign "{\"role\":\"anon\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}")
service_key=$(sign "{\"role\":\"service_role\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}")

echo ""
echo "هيتغيّر في .env:  JWT_SECRET · ANON_KEY · SERVICE_ROLE_KEY"
echo "ومش هيتلمس:      أي مفتاح تاني"
printf "نكمّل؟ (y/N) "
read -r REPLY
case "$REPLY" in [Yy]) ;; *) echo "اتلغى. مفيش حاجة اتغيّرت."; exit 0 ;; esac

backup=".env.before-jwt-$(date +%Y%m%d-%H%M%S)"
cp .env "$backup"
echo "✓ نسخة احتياطية: $backup"

# base64 مفيهوش | ولا & ولا \ — فالـsed بفاصل | آمن
sed -i \
  -e "s|^JWT_SECRET=.*$|JWT_SECRET=${jwt_secret}|" \
  -e "s|^ANON_KEY=.*$|ANON_KEY=${anon_key}|" \
  -e "s|^SERVICE_ROLE_KEY=.*$|SERVICE_ROLE_KEY=${service_key}|" \
  .env
echo "✓ .env اتحدّث"

# بعض دوال القاعدة القديمة بتقرا الختم من إعداد القاعدة مش من البيئة
if docker compose exec -T db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q \
     -c "ALTER DATABASE postgres SET \"app.settings.jwt_secret\" TO '${jwt_secret}';" >/dev/null 2>&1; then
  echo "✓ إعداد app.settings.jwt_secret في القاعدة اتحدّث"
else
  echo "⚠ ماقدرتش أحدّث app.settings.jwt_secret في القاعدة — كمّل عادي وقول لـClaude"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " ANON_KEY الجديد — ده مفتاح عام، آمن تبعته لـClaude:"
echo "════════════════════════════════════════════════════"
echo "$anon_key"
echo "════════════════════════════════════════════════════"
echo ""
echo "⚠️ ماتبعتش أي حاجة تانية من اللي فوق."
echo "الخطوة الجاية:  docker compose up -d --force-recreate"
