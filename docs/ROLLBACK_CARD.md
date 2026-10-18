# 🔴 كرت الرجوع — اقرأه في دقيقة

**القاعدة:** الرجوع **قرار أول ساعة**. المرآة اتجاه واحد (سحابة ← سيرفر)،
فأي شغل اتعمل على السيرفر بعد التحويل **مش هيرجع للسحابة**. بعد ساعتين
الرجوع بيكلّف بيانات.

---

## الرجوع الكامل — ٤ أوامر بالترتيب

```bash
# ١) السيرفر يرجع لوضع العزل (تريجرات تتعطّل · كرونات تتشال · المرآة ترجع)
/root/phalix-repo/scripts/cutover.sh rollback

# ٢) الشاشات وتطبيق الطيار يرجعوا للسحابة  (من جهازك مش السيرفر)
./scripts/switch-backend.sh cloud

# ٣) كرونات السحابة ترجع  (SQL Editor على السحابة)
#    do $$ declare r record; begin
#      for r in select jobid from cron.job where not active loop
#        perform cron.alter_job(r.jobid, active := true);
#      end loop; end $$;

# ٤) n8n يرجع للسحابة — التفصيل تحت
```

---

## n8n — الرجوع بالترتيب العكسي

| # | اللي اتغيّر | الرجوع |
|---|---|---|
| 1 | كريدنشيال `Postgres account` | **رجّع قيم السحابة** ← 🔴 لازم تكون مكتوبة عندك **قبل** التحويل |
| 2 | `login`: ٣ عقد → `Supabase server` | رجّعهم `Supabase account` (قايمة منسدلة) |
| 3 | `login`: ٤ روابط + مفتاح «إنشاء رمز الاستعادة» | رجّع عنوان السحابة |
| 4 | `login`: الختم في `Generate Token` + `Generate JWT` | رجّع ختم السحابة |
| 5 | `docker-compose` بتاع n8n: سطرين `SUPABASE_*` | رجّعهم لقيم السحابة + `docker compose up -d n8n` |
| 6 | الورك فلوز كلها | `docker exec n8n n8n import:workflow --input=/tmp/wf_backup.json` |

**نسخة كاملة قبل أي تعديل:**
```bash
docker exec -u node n8n n8n export:workflow --all --output=/tmp/wf_backup.json
docker cp n8n:/tmp/wf_backup.json /root/wf_backup_$(date +%Y%m%d_%H%M).json
```

---

## تطبيق الطيار

```sql
-- على السحابة: وقّف التحديث الإجباري
update driver_app_version set force_update = false where id = 1;
```

الطيارين على **بناء 73** بيرجعوا للسحابة لوحدهم خلال نص ساعة (بيقروا
`app-config.json`). اللي على نسخ أقدم ماكانوا اتحركوا أصلًا.

---

## قبل ما ترجع — اعرف إيه اللي هيضيع

```sql
-- على **السيرفر**: أي شغل حصل بعد لحظة التحويل
-- بدّل الوقت بوقت cutover.sh go
select 'orders'  as الجدول, count(*) from orders  where updated_at > '____'
union all select 'trips',   count(*) from trips   where updated_at > '____'
union all select 'order_logs', count(*) from order_logs where created_at > '____'
union all select 'driver_attendance', count(*) from driver_attendance where created_at > '____';
```

**أي رقم هنا = شغل هيضيع بالرجوع.** صفر = الرجوع مجاني. رقم كبير =
الأفضل تكمّل قدّام وتصلّح، مش ترجع.

---

## لو القاعدة نفسها بوظت

```bash
ls -1t /root/backups | head -3
# الاستعادة: docs/server_backup_restore.md (⚠️ docker cp مش أنبوب)
```

---

## الفرق بين «وقف» و«ارجع»

| العرض | التصرف |
|---|---|
| شاشة واحدة بتقع | **ماترجعش** — صلّحها. الرجوع تكلفته أكبر |
| كل الموظفين مش بيقدروا يدخلوا | الختم في n8n — صلّحه، مش رجوع |
| الطلبات مش بتوصل من eplus | كريدنشيال Postgres في n8n |
| القاعدة مش رادّة / الأرقام غلط | **ارجع فورًا** |

الرجوع لحاجة واحدة مكسورة بيكلّفك ساعة شغل ضايع. اسأل: «ده بند واحد
ولا النظام؟».
