#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  يوم التحويل — الجزء اللي على السيرفر
# ═══════════════════════════════════════════════════════════════════
#  التحويل حاجتين منفصلتين:
#    • السيرفر (الملف ده): مزامنة أخيرة · فك عزل الإشعارات · تشغيل الكرونات
#    • جهازك (switch-backend.sh): تحويل الشاشات وتطبيق الطيار
#
#  ⚠️ الترتيب مش اختياري:
#    1. وقّف كرونات السحابة و n8n     ← عشان مايجيش داتا جديدة بعد المزامنة
#    2. cutover.sh go                  ← مزامنة أخيرة + تشغيل السيرفر
#    3. switch-backend.sh server       ← الشاشات والتطبيقات تتحوّل
#    4. وجّه n8n لقاعدة السيرفر
#
#  لو عكست 1 و2، الداتا اللي دخلت السحابة بين المزامنة والتوقيف **بتضيع**.
#
#  ⚠️⚠️ أخطر بند: فك عزل الإشعارات. لو السحابة لسه شغّالة بتريجراتها،
#  الطيار هياخد الإشعار **مرتين**. اتأكد إنها وقفت قبل الخطوة دي.
#
#  الاستعمال:
#     ./cutover.sh check      # جاهزين؟ (بيقرا بس)
#     ./cutover.sh status     # إحنا فين دلوقتي؟
#     ./cutover.sh go         # التحويل (بيسأل قبلها)
#     ./cutover.sh rollback   # الرجوع — بيرجّع السيرفر لوضع العزل
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

COMPOSE_DIR="${PHALIX_COMPOSE_DIR:-/root/supabase-project}"
REPO="${PHALIX_REPO_DIR:-/root/phalix-repo}"
DB_USER="${PHALIX_DB_USER:-supabase_admin}"
DOMAIN="${PHALIX_DOMAIN:-https://supabase.ebrahimhamdy.com}"
BACKUP_DIR="${PHALIX_BACKUP_DIR:-/root/backups}"

TRIGGERS="orders:trg_notify_fcm_on_assign orders:trg_notify_on_driver_change orders:trg_fail_perf trips:trip_return_perf_trg orders:trg_delivery_perf"

cd "$COMPOSE_DIR" 2>/dev/null || { echo "✗ مجلد سوبابيز مش موجود"; exit 1; }
CID="$(docker compose ps -q db 2>/dev/null | head -1)"
[ -n "$CID" ] || { echo "✗ حاوية القاعدة مش لاقيها"; exit 1; }
q() { docker exec -i "$CID" psql -U "$DB_USER" -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }
run() { docker exec -i "$CID" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 "$@"; }

if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else G=''; Y=''; R=''; B=''; N=''; fi

# ── الحالة الحالية ─────────────────────────────────────────────────
cmd_status() {
  echo "${B}── حالة السيرفر ──${N}"
  printf '  مهام cron شغّالة   : %s\n' "$(q 'select count(*) from cron.job')"
  local on=0 off=0 miss=0
  for t in $TRIGGERS; do
    local tbl="${t%%:*}" nm="${t##*:}"
    local st; st="$(q "select tgenabled from pg_trigger t join pg_class c on c.oid=t.tgrelid where c.relname='$tbl' and t.tgname='$nm'")"
    case "$st" in O) on=$((on+1));; D) off=$((off+1));; *) miss=$((miss+1));; esac
  done
  printf '  تريجرات الإشعارات  : %s شغّالة · %s معطّلة · %s مش موجودة\n' "$on" "$off" "$miss"
  printf '  آخر مزامنة        : من %s ساعة\n' "$(q 'select coalesce(round(extract(epoch from now()-max(ran_at))/3600)::int,999) from public.cloud_sync_log')"
  printf '  مزامنة المرآة     : %s\n' "$(crontab -l 2>/dev/null | grep -q '^[^#].*sync-from-cloud' && echo 'شغّالة (قبل التحويل)' || echo 'موقوفة (بعد التحويل)')"
  printf '  أسرار vault       : %s من 6\n' "$(q 'select count(*) from vault.decrypted_secrets')"
  printf '  التطبيقات بتشاور على: %s\n' "$(curl -s --max-time 10 https://phalix.ebrahimhamdy.com/app-config.json 2>/dev/null | grep -o '"pointsTo"[^,]*' | cut -d'"' -f4 || echo '؟')"
  echo
  if [ "$on" = 0 ]; then
    echo "  ${Y}⇒ السيرفر في وضع العزل (قبل التحويل)${N}"
  else
    echo "  ${G}⇒ السيرفر في وضع التشغيل (بعد التحويل)${N}"
  fi
}

# ── جاهزين؟ ────────────────────────────────────────────────────────
cmd_check() {
  local bad=0
  echo "${B}── فحص الجاهزية ──${N}"
  ck() { if [ "$2" = ok ]; then printf '  %s✓%s %s\n' "$G" "$N" "$1"; else printf '  %s✗%s %s — %s\n' "$R" "$N" "$1" "$2"; bad=$((bad+1)); fi; }

  local d; d="$(run -q < "$REPO/docs/schema_drift_watch.sql" 2>&1 | grep -c '⚠️')"
  [ "${d:-1}" = 0 ] && ck "السكيما مطابقة للسحابة" ok || ck "السكيما" "فيه انحراف — شغّل schema_drift_watch.sql"

  local v; v="$(q 'select count(*) from vault.decrypted_secrets')"
  [ "${v:-0}" -ge 6 ] && ck "أسرار vault ($v)" ok || ck "أسرار vault" "$v من 6 — شغّل setup-vault-secrets.sh"

  local last; last="$(ls -1d "$BACKUP_DIR"/2* 2>/dev/null | tail -1)"
  if [ -n "$last" ] && [ $(( ( $(date +%s) - $(stat -c %Y "$last") ) / 3600 )) -lt 30 ]; then
    ck "نسخة احتياطية حديثة" ok
  else ck "نسخة احتياطية" "قديمة أو مفيش — شغّل server-backup.sh"; fi

  if command -v rclone >/dev/null && [ -n "$(rclone lsf "${PHALIX_REMOTE:-gdrive:phalix-backups}" 2>/dev/null | grep '\.enc$' | tail -1)" ]; then
    ck "نسخة خارجية على Drive" ok
  else ck "نسخة خارجية" "مفيش — شغّل backup-offsite.sh"; fi

  local h; h="$(q 'select coalesce(round(extract(epoch from now()-max(ran_at))/3600)::int,999) from public.cloud_sync_log')"
  [ "${h:-999}" -lt 30 ] && ck "المزامنة حديثة (من $h ساعة)" ok || ck "المزامنة" "من $h ساعة"

  local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://phalix.ebrahimhamdy.com/app-config.json)"
  [ "$c" = 200 ] && ck "ملف إعداد التطبيقات شغّال" ok || ck "ملف إعداد التطبيقات" "HTTP $c"

  local ak; ak="$(grep -m1 '^ANON_KEY=' .env | cut -d= -f2- | tr -d '"\r')"
  local rc; rc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "apikey: $ak" -H "Authorization: Bearer $ak" "$DOMAIN/rest/v1/branches?select=name&limit=1")"
  [ "$rc" = 200 ] && ck "الـAPI رادّ من برّه" ok || ck "الـAPI" "HTTP $rc"

  echo
  [ "$bad" = 0 ] && echo "  ${G}${B}جاهزين${N}" || echo "  ${R}${B}$bad بند لسه ناقص${N}"
  return $bad
}

# ── التحويل ────────────────────────────────────────────────────────
cmd_go() {
  cmd_status; echo
  cat <<EOF
${Y}${B}⚠️ قبل ما تكمّل، اتأكد إن دول اتعملوا:${N}
   1. كرونات السحابة اتوقفت (cron.alter_job active := false)
   2. مزامنات n8n اتوقفت
   3. مفيش رحلة شغّالة دلوقتي

لو السحابة لسه شغّالة، الطيار هياخد كل إشعار **مرتين**.
EOF
  printf "\nنكمّل؟ اكتب %sتحويل%s: " "$B" "$N"
  read -r a; [ "$a" = "تحويل" ] || { echo "اتلغى."; exit 0; }

  printf '\n'; echo "${B}[1/4] مزامنة أخيرة${N}"
  "$REPO/scripts/sync-from-cloud.sh" --days 2 || { echo "${R}✗ المزامنة فشلت — وقفنا هنا${N}"; exit 1; }

  printf '\n'; echo "${B}[1.5/4] إيقاف مزامنة المرآة${N}"
  # 🔴 لازم تتوقف هنا بالظبط — البند ده كان ناقص في الدليل:
  #    بعد التحويل السحابة بتبقى متجمّدة، والمزامنة بتاخد صفوفها
  #    وتحطها مكان المحلي. يعني بترجّع البيانات الحية لورا:
  #    طلب اتسلّم يرجع «قيد التوصيل»، رحلة اتقفلت تفتح تاني.
  #    وأخطر حاجة إنها مابتبانش بسرعة — مفيش حاجة بتختفي، بس
  #    الحالة بترجع قديمة، فتفتكرها غلطة موظف مش مزامنة.
  if crontab -l 2>/dev/null | grep -q '^[^#].*sync-from-cloud'; then
    crontab -l 2>/dev/null | sed '/sync-from-cloud/ s|^|# [اتوقفت يوم التحويل] |' > /tmp/.cron.$$ \
      && crontab /tmp/.cron.$$ && rm -f /tmp/.cron.$$
    echo "  ✓ مزامنة المرآة اتوقفت"
  else
    echo "  (موقوفة خلاص أو مش في الكرون)"
  fi
  echo "  ℹ️ النسخ الاحتياطي وفحص الصحة بيفضلوا شغّالين زي ما هما"

  printf '\n'; echo "${B}[2/4] فك عزل الإشعارات وتقييم الأداء${N}"
  for t in $TRIGGERS; do
    local tbl="${t%%:*}" nm="${t##*:}"
    if q "select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid where c.relname='$tbl' and t.tgname='$nm'" | grep -q 1; then
      run -c "alter table public.$tbl enable trigger $nm" >/dev/null && echo "  ✓ $nm"
    else echo "  ⚠️ $nm مش موجود — اتخطّى"; fi
  done

  printf '\n'; echo "${B}[3/4] تشغيل الكرونات${N}"
  local before; before="$(q 'select count(*) from cron.job')"
  if [ "${before:-0}" != "0" ]; then
    echo "  ⚠️ فيه $before مهمة شغّالة خلاص — مش هنضيف تاني (شغّل rollback الأول لو عايز تعيد)"
  else
    run <<'SQL' >/dev/null
do $$
declare r record; n int := 0;
begin
  for r in select ddl from cloudsrc.v_migration_post where kind = 'cron' loop
    begin
      execute replace(r.ddl, '__TARGET_URL__', 'https://supabase.ebrahimhamdy.com');
      n := n + 1;
    exception when others then
      raise notice '  ⚠️ مهمة فشلت: %', left(sqlerrm, 90);
    end;
  end loop;
  raise notice '  ✓ % مهمة اتجدولت', n;
end $$;
SQL
    echo "  المهام دلوقتي: $(q 'select count(*) from cron.job')"
  fi

  printf '\n'; echo "${B}[4/4] التحقق${N}"
  cmd_status

  cat <<EOF

${G}${B}الجزء اللي على السيرفر خلص.${N}

الباقي **مش هنا**:
  ${B}أ)${N} على جهازك — تحويل الشاشات والتطبيقات:
       ./scripts/switch-backend.sh server
  ${B}ب)${N} n8n — وصّله بقاعدة السيرفر (مرة واحدة):
       docker network connect supabase_default n8n
       وبعدين في كريدنشيال n8n: Host = db · Port = 5432
  ${B}ج)${N} GitHub — سر نشر التطبيق:
       APK_PUBLISH_SECRET = قيمة apk_publish_secret من vault
       ورابط الدالة في .github/workflows/build-apk.yml للسيرفر

${Y}راقب أول ساعة:${N} افتح شاشة التوزيع، اعمل طلب تجريبي، وشوف الطيار
بياخد الإشعار. ولو حصلت مشكلة: ${B}./cutover.sh rollback${N}
EOF
}

# ── الرجوع ─────────────────────────────────────────────────────────
cmd_rollback() {
  echo "${Y}${B}الرجوع: السيرفر هيرجع لوضع العزل${N}"
  echo "(الشاشات والتطبيقات بترجع بـswitch-backend.sh cloud على جهازك)"
  printf "\nنكمّل؟ (y/N) "; read -r a
  case "$a" in [Yy]) ;; *) echo "اتلغى."; exit 0 ;; esac

  printf '\n'; echo "[1/2] إيقاف الكرونات"
  run <<'SQL' >/dev/null
do $$
declare r record; n int := 0;
begin
  for r in select jobid from cron.job loop
    perform cron.unschedule(r.jobid); n := n + 1;
  end loop;
  raise notice '  ✓ % مهمة اتوقفت', n;
end $$;
SQL
  echo "  المهام دلوقتي: $(q 'select count(*) from cron.job')"

  printf '\n'; echo "[1.5/2] إرجاع مزامنة المرآة"
  # الرجوع = السحابة رجعت مصدر الحقيقة تاني، فالمرآة لازم تشتغل
  if crontab -l 2>/dev/null | grep -q 'اتوقفت يوم التحويل'; then
    crontab -l 2>/dev/null | sed 's|^# \[اتوقفت يوم التحويل\] ||' > /tmp/.cron.$$ \
      && crontab /tmp/.cron.$$ && rm -f /tmp/.cron.$$
    echo "  ✓ مزامنة المرآة رجعت"
  else
    echo "  (مش لاقيها موقوفة)"
  fi

  printf '\n'; echo "[2/2] إعادة عزل الإشعارات"
  for t in $TRIGGERS; do
    local tbl="${t%%:*}" nm="${t##*:}"
    run -c "alter table public.$tbl disable trigger $nm" >/dev/null 2>&1 && echo "  ✓ $nm اتعطّل"
  done

  echo
  cmd_status
  cat <<EOF

${B}فاضل عليك:${N}
  • على جهازك:  ./scripts/switch-backend.sh cloud
  • رجّع كرونات السحابة:  cron.alter_job(jobid, active := true)
  • رجّع n8n لكريدنشيال السحابة
EOF
}

case "${1:-}" in
  check)    cmd_check ;;
  status)   cmd_status ;;
  go)       cmd_go ;;
  rollback) cmd_rollback ;;
  *) sed -n '2,28p' "$0" ;;
esac
