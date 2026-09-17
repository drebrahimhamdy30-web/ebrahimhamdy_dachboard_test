# النسخ الاحتياطي للسيرفر الذاتي — والرجوع منه

**السيرفر:** `supabase.ebrahimhamdy.com` (193.181.208.115) · **بدأ:** 2026-09-17

السكربت: `scripts/server-backup.sh` · بينسخ في `/root/backups/YYYYMMDD-HHMM/`

---

## ياخد إيه — وليه الأربعة مع بعض

| الملف | فيه إيه | من غيره بيحصل إيه |
|---|---|---|
| `db.dump` | القاعدة كلها (بيانات + جداول + دوال + صلاحيات) | مفيش رجوع أصلًا |
| `globals.sql` | الأدوار وكلمات سرها | الاستيراد بيقف: `role "supabase_admin" does not exist` |
| `config.tar.gz` | `.env` + `docker-compose.yml` + الدوال | القاعدة ترجع بس سوبابيز مايقومش (الأختام والمفاتيح ضاعت) |
| `storage.tar.gz` | ملفات التخزين (صور/مرفقات) | الصفوف موجودة والملفات مش موجودة |

⚠️ `config.tar.gz` **فيه أسرار** — المجلد `700` والملفات `600`. ماترفعهوش على مكان عام.

---

## الاستعمال

```bash
/root/phalix-repo/scripts/server-backup.sh          # ياخد نسخة
/root/phalix-repo/scripts/server-backup.sh -n       # تجربة من غير ما يكتب
/root/phalix-repo/scripts/server-backup.sh --verify-last   # يتأكد إن آخر نسخة سليمة
```

**الاستبقاء:** آخر ١٤ نسخة + نسخة الجمعة لآخر ٨ أسابيع. الباقي بيتمسح لوحده.

**كل نسخة بتتفحص وهي بتتعمل:** الحجم معقول؟ الأرشيف سليم؟ و`pg_restore -l` بيقدر يقرا الفهرس؟ لو أي فحص فشل، السكربت بيفشل ويسيب النسخة مكانها للمراجعة — أحسن من نسخة بتبان تمام وتطلع فاضية يوم الحاجة.

### الكرون (يومي ٣ الفجر)

```
0 3 * * * /root/phalix-repo/scripts/server-backup.sh -q >> /var/log/phalix-backup.log 2>&1
```

`-q` = ساكت خالص لو كل حاجة تمام، وبيتكلم بس لو حصلت مشكلة — فاللوج مايبقاش ضجيج ومحدش يقراه.

---

## ⚠️ النسخة لازم تخرج برّه السيرفر

نسخة على نفس السيرفر بتحميك من: migration غلط، حذف بالغلط، جدول باظ.
**مابتحميكش من:** القرص يفصل، الحساب يتقفل، السيرفر يتخرق (الفدية بتمسح النسخ المحلية الأول).

اسحب على جهازك (من PowerShell على ويندوز):

```powershell
scp -r root@193.181.208.115:/root/backups/20260917-0300 D:\phalix-backups\
```

الأفضل طبعًا يبقى تلقائي (rclone على Google Drive أو Cloudflare R2) — قرار مؤجّل.

---

## الرجوع من نسخة

> ⚠️ ده بيمسح القاعدة الحالية ويحط مكانها القديمة. تأكد إنك ناوي.

```bash
cd /root/supabase-project
BK=/root/backups/20260917-0300        # غيّرها للنسخة المطلوبة

# ١) الأدوار الأول (قبل أي حاجة)
docker compose exec -T db psql -U supabase_admin -d postgres < $BK/globals.sql

# ٢) القاعدة — --clean بيمسح اللي موجود، -j4 أسرع
docker compose exec -T db pg_restore -U supabase_admin -d postgres \
  --clean --if-exists -j4 /dev/stdin < $BK/db.dump

# ٣) الإعدادات (لو محتاجها — دي بتكتب فوق .env الحالي!)
tar -xzf $BK/config.tar.gz -C /root/supabase-project

# ٤) قيام
docker compose up -d --force-recreate
```

**رجوع جدول واحد بس** (من غير ما تلمس الباقي):

```bash
docker compose exec -T db pg_restore -U supabase_admin -d postgres \
  --data-only -t sales_items /dev/stdin < $BK/db.dump
```

### أخطاء متوقّعة وقت الرجوع

| الرسالة | المعنى |
|---|---|
| `role ... does not exist` | نسيت خطوة ١ |
| `extension ... already exists` | عادي، تجاهلها |
| `must be owner of extension` | عادي مع `--clean` |
| بعد الرجوع الشاشات بترجّع 401 | الأختام في `.env` مش بتاعة الـdump — راجع `scripts/fix-jwks-oct.sh` |

---

## تجربة الرجوع

نسخة ماتجرّبتش = نسخة مش مضمونة. مرة كل فترة، جرّب الرجوع على قاعدة فاضية:

```bash
docker compose exec -T db createdb -U supabase_admin testrestore
docker compose exec -T db pg_restore -U supabase_admin -d testrestore -j4 /dev/stdin < $BK/db.dump
docker compose exec -T db psql -U supabase_admin -d testrestore -tAc \
  "select count(*) from public.orders"
docker compose exec -T db dropdb -U supabase_admin testrestore
```

لو العدد قريب من الحقيقي، النسخة موثوقة.
