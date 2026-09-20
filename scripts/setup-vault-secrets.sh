#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  أسرار vault على السيرفر الذاتي
# ═══════════════════════════════════════════════════════════════════
#  ٦ دوال بتقرا أسرارها من vault مش من متغيّرات البيئة. من غيرها
#  بتفشل **بصمت**: أوضح مثال driver-poll — لو driver_app_secret مش
#  موجود بترجّع {"events": []} من غير أي خطأ، يعني الطيارين مش
#  بياخدوا إشعارات والتطبيق مش بيشتكي.
#
#  ═══ ليه بعضها بيتنسخ وبعضها بيتولّد ═══
#  المبدأ: لو السيرفر اتخرق، السحابة تفضل سليمة. فالأصل إننا نولّد
#  قيم جديدة. الاستثناء بس لما القيمة **لازم تطابق حاجة برّه**:
#
#    driver_app_secret      → منسوخ: محروق في الـAPK، تغييره = نسخة
#                             جديدة + تحديث إجباري لكل الطيارين
#    مفتاح إشعارات الآيفون   → منسوخ: تغييره بيبطّل كل اشتراكات الـPWA
#                             الحالية ولازم كل سائق يعيد التسجيل
#    eplus_sync_key         → = SYNC_KEY في .env (الاتنين لازم يطابقوا)
#    الباقي (3)             → قيم جديدة: اللي بيقراها هو نفس القاعدة
#
#  ═══ النسخ بيتم من قاعدة لقاعدة ═══
#  عبر postgres_fdw الموجود أصلًا — القيم مابتعدّيش على الشاشة ولا على
#  أي أداة. السكربت بيطبع الأسماء والأطوال بس.
#
#  الاستعمال (من /root/supabase-project):
#     /root/phalix-repo/scripts/setup-vault-secrets.sh
#     /root/phalix-repo/scripts/setup-vault-secrets.sh --check   # عرض بس
#
#  آمن يتعاد تشغيله: السر الموجود مابيتلمسش.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

cd "$COMPOSE_DIR" 2>/dev/null || { echo "✗ مجلد سوبابيز مش موجود"; exit 1; }
CID="$(docker compose ps -q db 2>/dev/null | head -1)"
[ -n "$CID" ] || { echo "✗ حاوية القاعدة مش لاقيها"; exit 1; }
psql() { docker exec -i "$CID" psql -U "$DB_USER" -d postgres "$@"; }

show() {
  echo "── أسرار vault على السيرفر ──"
  psql -tAc "select '  ' || name || '  (' || length(decrypted_secret) || ' حرف)'
             from vault.decrypted_secrets order by name" 2>/dev/null \
    || echo "  (مفيش vault؟)"
}

if [ "$CHECK" = 1 ]; then show; exit 0; fi

# SYNC_KEY من .env — لازم يطابق eplus_sync_key
SK="$(grep -m1 '^SYNC_KEY=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d '\r')"
[ -n "$SK" ] || { echo "⚠️ SYNC_KEY مش موجود في .env — هنتخطّى eplus_sync_key"; }

echo "── تجهيز الأسرار ──"

# ── ١) المنسوخة من السحابة (قيمة لازم تطابق حاجة برّه) ─────────────
psql -v ON_ERROR_STOP=1 <<'SQL'
-- الـview بتاع vault على السحابة عبر الرابط الموجود.
-- ⚠️ القيم بتتنقل قاعدة لقاعدة — مابتظهرش في أي خرج.
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'cloudvault') then
    execute 'create schema cloudvault';
  end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='cloudvault' and c.relname='decrypted_secrets') then
    execute 'import foreign schema vault limit to (decrypted_secrets) from server cloud into cloudvault';
  end if;
end $$;

do $$
declare
  r record;
  -- الأسرار اللي قيمتها لازم تطابق حاجة خارج القاعدة
  copy_list constant text[] := array[
    'driver_app_secret',
    'مفتاح الخدمة لإرسال الإشعارات'
  ];
  n int := 0;
begin
  for r in
    select name, decrypted_secret, coalesce(description,'') as description
    from cloudvault.decrypted_secrets
    where name = any (copy_list)
  loop
    if exists (select 1 from vault.decrypted_secrets v where v.name = r.name) then
      raise notice '  = %  (موجود خلاص — مالمسناهوش)', r.name;
    else
      perform vault.create_secret(r.decrypted_secret, r.name, r.description);
      raise notice '  ✓ %  (اتنسخ من السحابة)', r.name;
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise notice '  (مفيش جديد اتنسخ)'; end if;
exception when others then
  raise notice '  ⚠️ النسخ من السحابة فشل: %', left(sqlerrm, 120);
  raise notice '     (الرابط بالسحابة شغّال؟ جرّب: select count(*) from cloudsrc.branches)';
end $$;
SQL

# ── ٢) المولّدة محليًا ─────────────────────────────────────────────
for s in backup_trigger_token perf_functions_secret apk_publish_secret; do
  exists=$(psql -tAc "select count(*) from vault.decrypted_secrets where name = '$s'" | tr -d ' ')
  if [ "$exists" != "0" ]; then
    echo "  = $s  (موجود خلاص)"
    continue
  fi
  val="$(openssl rand -hex 24)"
  psql -v ON_ERROR_STOP=1 -tAc \
    "select vault.create_secret('$val', '$s', 'قيمة جديدة اتولّدت على السيرفر — مش نسخة من السحابة')" >/dev/null
  echo "  ✓ $s  (قيمة جديدة)"
done

# ── ٣) eplus_sync_key = SYNC_KEY في .env ───────────────────────────
if [ -n "$SK" ]; then
  exists=$(psql -tAc "select count(*) from vault.decrypted_secrets where name = 'eplus_sync_key'" | tr -d ' ')
  if [ "$exists" != "0" ]; then
    echo "  = eplus_sync_key  (موجود خلاص)"
  else
    printf '%s' "$SK" > /tmp/.sk.$$
    docker exec -i "$CID" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -tAc \
      "select vault.create_secret(\$k\$$(cat /tmp/.sk.$$)\$k\$, 'eplus_sync_key', 'نفس قيمة SYNC_KEY في .env — لازم الاتنين يطابقوا')" >/dev/null
    rm -f /tmp/.sk.$$
    echo "  ✓ eplus_sync_key  (= SYNC_KEY بتاع السيرفر)"
  fi
fi

echo
show
echo
echo "⚠️ فاضل بعد كده (بنود تحويل، مش دلوقتي):"
echo "   • apk_publish_secret الجديد لازم يتحط في GitHub → Settings → Secrets"
echo "     باسم APK_PUBLISH_SECRET، ورابط الدالة في الـworkflow يتغيّر للسيرفر"
echo "   • اقرا قيمته بـ:  docker exec -i \$(docker compose ps -q db) psql -U $DB_USER \\"
echo "       -d postgres -tAc \"select decrypted_secret from vault.decrypted_secrets\\"
echo "        where name='apk_publish_secret'\""
